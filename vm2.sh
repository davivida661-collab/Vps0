#!/bin/bash
# =============================
# Enhanced Multi-VM Manager (Pure QEMU Version)
# Version: 2.1.0 — Fixed & Improved
# =============================
set -euo pipefail

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
display_header() {
    clear
    cat << "EOF"
 ███████████                            █████   █████                     ████████ 
░░███░░░░░███                          ░░███   ░░███                     ███░░░░███
 ░███    ░███  █████ ████ ████████      ░███    ░███  █████████████     ░░░    ░███
 ░██████████  ░░███ ░███ ░░███░░███     ░███    ░███ ░░███░░███░░███       ███████ 
 ░███░░░░░███  ░███ ░███  ░███ ░███     ░░███   ███   ░███ ░███ ░███      ███░░░░  
 ░███    ░███  ░███ ░███  ░███ ░███      ░░░█████░    ░███ ░███ ░███     ███      █
 █████   █████ ░░████████ ████ █████       ░░███      █████░███ █████   ░██████████
░░░░░   ░░░░░   ░░░░░░░░ ░░░░ ░░░░░         ░░░      ░░░░░ ░░░ ░░░░░    ░░░░░░░░░░
EOF
    echo
}

# ---------------------------------------------------------------------------
# Colored output
# ---------------------------------------------------------------------------
print_status() {
    local type=$1
    local message=$2
    case $type in
        "INFO")    echo -e "\033[1;34m📋 [INFO]\033[0m $message" ;;
        "WARN")    echo -e "\033[1;33m⚠️  [WARN]\033[0m $message" ;;
        "ERROR")   echo -e "\033[1;31m❌ [ERROR]\033[0m $message" ;;
        "SUCCESS") echo -e "\033[1;32m✅ [SUCCESS]\033[0m $message" ;;
        "INPUT")   echo -e "\033[1;36m🎯 [INPUT]\033[0m $message" ;;
        *)         echo "[$type] $message" ;;
    esac
}

# ---------------------------------------------------------------------------
# FIX #1: cleanup uses $VM_DIR-relative paths, not CWD
# FIX: use a dedicated temp dir so seed files never land in CWD
# ---------------------------------------------------------------------------
TMPDIR_VM=""

cleanup() {
    if [[ -n "$TMPDIR_VM" && -d "$TMPDIR_VM" ]]; then
        rm -rf "$TMPDIR_VM"
    fi
}

# Set the trap early but after TMPDIR_VM is defined
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
check_dependencies() {
    local deps=("qemu-system-x86_64" "qemu-img" "cloud-localds")
    local optional_deps=("lsof" "ss" "openssl")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -ne 0 ]]; then
        print_status "ERROR" "Missing required dependencies: ${missing[*]}"
        print_status "INFO"  "On Ubuntu/Debian: sudo apt install qemu-system-x86 cloud-image-utils"
        print_status "INFO"  "On Fedora/RHEL:   sudo dnf install qemu-system-x86 cloud-utils"
        exit 1
    fi

    # Optional: warn but don't exit
    for dep in "${optional_deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            print_status "WARN" "Optional tool '$dep' not found — some features may be limited"
        fi
    done

    # Download tool: prefer wget, fall back to curl
    if command -v wget &>/dev/null; then
        DOWNLOADER="wget"
    elif command -v curl &>/dev/null; then
        DOWNLOADER="curl"
    else
        print_status "ERROR" "Neither wget nor curl found. Install one to download images."
        exit 1
    fi
    export DOWNLOADER
}

# ---------------------------------------------------------------------------
# KVM detection
# ---------------------------------------------------------------------------
detect_accel() {
    if [[ -e /dev/kvm ]] && [[ -r /dev/kvm ]] && [[ -w /dev/kvm ]]; then
        echo "kvm"
    else
        echo "tcg"
    fi
}

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
validate_input() {
    local type=$1
    local value=$2
    case $type in
        "number")
            if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                print_status "ERROR" "Must be a positive integer"
                return 1
            fi
            ;;
        "size")
            if ! [[ "$value" =~ ^[0-9]+[GgMm]$ ]]; then
                print_status "ERROR" "Must be a size with unit (e.g., 20G, 512M)"
                return 1
            fi
            ;;
        "port")
            if ! [[ "$value" =~ ^[0-9]+$ ]] || (( value < 1024 || value > 65535 )); then
                print_status "ERROR" "Must be a valid unprivileged port (1024-65535)"
                return 1
            fi
            ;;
        "name")
            if ! [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                print_status "ERROR" "Only letters, numbers, hyphens, and underscores allowed"
                return 1
            fi
            ;;
        "username")
            if ! [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                print_status "ERROR" "Must start with a letter/underscore; only lowercase letters, numbers, hyphens, underscores"
                return 1
            fi
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# Image lock check
# FIX #2 (show_vm_info): provide a non-interactive variant
# ---------------------------------------------------------------------------
# Returns 0 if unlocked (safe to use), 1 if locked
check_image_lock_silent() {
    local img_file=$1

    # Check if QEMU is already using this image
    if command -v lsof &>/dev/null && lsof "$img_file" 2>/dev/null | grep -q qemu-system; then
        return 1
    fi

    # Check for stale lock files
    local lock_file="${img_file}.lock"
    if [[ -f "$lock_file" ]]; then
        # Stale if older than 5 min and no associated QEMU process
        if [[ -n "$(find "$lock_file" -mmin +5 2>/dev/null)" ]]; then
            rm -f "$lock_file" 2>/dev/null || true
            return 0
        fi
        return 1
    fi
    return 0
}

check_image_lock() {
    local img_file=$1
    local vm_name=$2

    if command -v lsof &>/dev/null && lsof "$img_file" 2>/dev/null | grep -q qemu-system; then
        print_status "WARN" "Image file $img_file is already in use by another QEMU process"

        local pid
        pid=$(lsof "$img_file" 2>/dev/null | awk '/qemu-system/{print $2; exit}')
        if [[ -n "$pid" ]]; then
            print_status "INFO" "Process ID using the image: $pid"

            if ps -p "$pid" -o cmd= 2>/dev/null | grep -q "$vm_name"; then
                print_status "INFO" "This appears to be the same VM already running"
                read -rp "$(print_status "INPUT" "Kill existing process and restart? (y/N): ")" kill_choice
                if [[ "$kill_choice" =~ ^[Yy]$ ]]; then
                    kill "$pid" 2>/dev/null || true
                    sleep 2
                    if kill -0 "$pid" 2>/dev/null; then
                        kill -9 "$pid" 2>/dev/null || true
                        print_status "WARN" "Forcefully terminated process $pid"
                    fi
                    return 0
                else
                    return 1
                fi
            else
                print_status "ERROR" "Another QEMU instance is using this image"
                return 1
            fi
        fi
        return 1
    fi

    local lock_file="${img_file}.lock"
    if [[ -f "$lock_file" ]]; then
        print_status "WARN" "Lock file found: $lock_file"

        if [[ -n "$(find "$lock_file" -mmin +5 2>/dev/null)" ]]; then
            print_status "WARN" "Lock file appears stale (older than 5 minutes)"
            read -rp "$(print_status "INPUT" "Remove stale lock file? (y/N): ")" remove_lock
            if [[ "$remove_lock" =~ ^[Yy]$ ]]; then
                rm -f "$lock_file"
                print_status "SUCCESS" "Removed stale lock file"
                return 0
            else
                return 1
            fi
        fi
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# VM list / config helpers
# ---------------------------------------------------------------------------
get_vm_list() {
    find "$VM_DIR" -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort
}

load_vm_config() {
    local vm_name=$1
    local config_file="$VM_DIR/$vm_name.conf"

    if [[ -f "$config_file" ]]; then
        unset VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD
        unset DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE PORT_FORWARDS IMG_FILE SEED_FILE CREATED
        # shellcheck source=/dev/null
        source "$config_file"
        return 0
    else
        print_status "ERROR" "Configuration for VM '$vm_name' not found"
        return 1
    fi
}

save_vm_config() {
    local config_file="$VM_DIR/$VM_NAME.conf"

    cat > "$config_file" <<EOF
VM_NAME="$VM_NAME"
OS_TYPE="$OS_TYPE"
CODENAME="$CODENAME"
IMG_URL="$IMG_URL"
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
PASSWORD="$PASSWORD"
DISK_SIZE="$DISK_SIZE"
MEMORY="$MEMORY"
CPUS="$CPUS"
SSH_PORT="$SSH_PORT"
GUI_MODE="$GUI_MODE"
PORT_FORWARDS="$PORT_FORWARDS"
IMG_FILE="$IMG_FILE"
SEED_FILE="$SEED_FILE"
CREATED="$CREATED"
EOF

    print_status "SUCCESS" "Configuration saved to $config_file"
}

# ---------------------------------------------------------------------------
# FIX #3: is_vm_running — does NOT call load_vm_config to avoid corrupting
#          the caller's loaded VM state. It derives the image path directly.
# ---------------------------------------------------------------------------
is_vm_running() {
    local vm_name=$1
    local img_path

    # Quick check by VM name in process list
    if pgrep -f "qemu-system.*${vm_name}" >/dev/null 2>&1; then
        return 0
    fi

    # Derive image path without touching global variables
    local config_file="$VM_DIR/$vm_name.conf"
    if [[ -f "$config_file" ]]; then
        img_path=$(grep '^IMG_FILE=' "$config_file" | cut -d'"' -f2)
        if [[ -n "$img_path" ]] && pgrep -f "qemu-system.*${img_path}" >/dev/null 2>&1; then
            return 0
        fi
    fi

    return 1
}

# ---------------------------------------------------------------------------
# FIX #4: setup_vm_image — temp files go to $TMPDIR_VM, not CWD
# FIX #5: fallback image creation no longer references the deleted file
# ---------------------------------------------------------------------------
setup_vm_image() {
    print_status "INFO" "Preparing VM image..."

    mkdir -p "$VM_DIR"

    # --- Download ---
    if [[ -f "$IMG_FILE" ]]; then
        print_status "INFO" "Image file already exists — skipping download."
    else
        print_status "INFO" "Downloading image from $IMG_URL ..."
        local tmp_dl="${IMG_FILE}.downloading"

        if [[ "$DOWNLOADER" == "wget" ]]; then
            if ! wget --show-progress -q "$IMG_URL" -O "$tmp_dl"; then
                rm -f "$tmp_dl"
                print_status "ERROR" "Failed to download image from $IMG_URL"
                exit 1
            fi
        else
            if ! curl -L --progress-bar "$IMG_URL" -o "$tmp_dl"; then
                rm -f "$tmp_dl"
                print_status "ERROR" "Failed to download image from $IMG_URL"
                exit 1
            fi
        fi
        mv "$tmp_dl" "$IMG_FILE"
        print_status "SUCCESS" "Download complete."
    fi

    # --- Resize ---
    # FIX: if resize fails, convert to a new qcow2 of the right size (don't reference deleted file)
    print_status "INFO" "Resizing disk image to $DISK_SIZE ..."
    if ! qemu-img resize "$IMG_FILE" "$DISK_SIZE" 2>/dev/null; then
        print_status "WARN" "In-place resize failed — creating a fresh qcow2 overlay..."
        local tmp_img="${IMG_FILE}.new"
        # Create a properly-sized qcow2 backed by the original
        if qemu-img convert -f qcow2 -O qcow2 "$IMG_FILE" "$tmp_img" && \
           qemu-img resize "$tmp_img" "$DISK_SIZE"; then
            mv "$tmp_img" "$IMG_FILE"
            print_status "SUCCESS" "Image converted and resized."
        else
            rm -f "$tmp_img"
            print_status "WARN" "Could not resize disk; VM will use original image size."
        fi
    fi

    # --- cloud-init seed (temp files in $TMPDIR_VM, not CWD) ---
    TMPDIR_VM=$(mktemp -d)

    # Hash password — prefer openssl, fall back to python3, then plain text (dev only)
    local hashed_pass
    if command -v openssl &>/dev/null; then
        hashed_pass=$(openssl passwd -6 "$PASSWORD" 2>/dev/null)
    elif command -v python3 &>/dev/null; then
        hashed_pass=$(python3 -c "import crypt,getpass; print(crypt.crypt('$PASSWORD', crypt.mksalt(crypt.METHOD_SHA512)))" 2>/dev/null)
    else
        print_status "WARN" "openssl and python3 unavailable — storing password as plain text (insecure!)"
        hashed_pass="$PASSWORD"
    fi

    cat > "$TMPDIR_VM/user-data" <<CLOUDINIT
#cloud-config
hostname: $HOSTNAME
fqdn: ${HOSTNAME}.local
manage_etc_hosts: true
ssh_pwauth: true
disable_root: false
users:
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: ${hashed_pass}
chpasswd:
  expire: false
  list:
    - root:$PASSWORD
    - ${USERNAME}:$PASSWORD
package_update: false
CLOUDINIT

    cat > "$TMPDIR_VM/meta-data" <<METAD
instance-id: iid-${VM_NAME}-$(date +%s)
local-hostname: $HOSTNAME
METAD

    if ! cloud-localds "$SEED_FILE" "$TMPDIR_VM/user-data" "$TMPDIR_VM/meta-data"; then
        print_status "ERROR" "Failed to create cloud-init seed image"
        exit 1
    fi

    rm -rf "$TMPDIR_VM"
    TMPDIR_VM=""

    print_status "SUCCESS" "VM '$VM_NAME' prepared successfully."
    print_status "INFO" "Login: username=$USERNAME  password=$PASSWORD"
    print_status "INFO" "SSH:   ssh -p $SSH_PORT ${USERNAME}@localhost"
}

# ---------------------------------------------------------------------------
# Create new VM
# ---------------------------------------------------------------------------
create_new_vm() {
    print_status "INFO" "Creating a new VM"

    # Build a sorted, numbered list from the associative array
    print_status "INFO" "Select an OS:"
    local os_keys=()
    # Sort keys for consistent ordering
    mapfile -t os_keys < <(printf '%s\n' "${!OS_OPTIONS[@]}" | sort)
    local idx
    for idx in "${!os_keys[@]}"; do
        printf "  %2d) %s\n" "$((idx + 1))" "${os_keys[$idx]}"
    done

    while true; do
        read -rp "$(print_status "INPUT" "Enter choice (1-${#os_keys[@]}): ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#os_keys[@]} )); then
            local os="${os_keys[$((choice - 1))]}"
            IFS='|' read -r OS_TYPE CODENAME IMG_URL DEFAULT_HOSTNAME DEFAULT_USERNAME DEFAULT_PASSWORD \
                <<< "${OS_OPTIONS[$os]}"
            print_status "SUCCESS" "Selected: $os"
            break
        else
            print_status "ERROR" "Invalid selection. Try again."
        fi
    done

    # VM Name
    while true; do
        read -rp "$(print_status "INPUT" "VM name (default: $DEFAULT_HOSTNAME): ")" VM_NAME
        VM_NAME="${VM_NAME:-$DEFAULT_HOSTNAME}"
        if validate_input "name" "$VM_NAME"; then
            if [[ -f "$VM_DIR/$VM_NAME.conf" ]]; then
                print_status "ERROR" "VM '$VM_NAME' already exists. Choose another name."
            else
                break
            fi
        fi
    done

    # Hostname
    while true; do
        read -rp "$(print_status "INPUT" "Hostname (default: $VM_NAME): ")" HOSTNAME
        HOSTNAME="${HOSTNAME:-$VM_NAME}"
        if validate_input "name" "$HOSTNAME"; then break; fi
    done

    # Username
    while true; do
        read -rp "$(print_status "INPUT" "Username (default: $DEFAULT_USERNAME): ")" USERNAME
        USERNAME="${USERNAME:-$DEFAULT_USERNAME}"
        if validate_input "username" "$USERNAME"; then break; fi
    done

    # Password
    while true; do
        read -rsp "$(print_status "INPUT" "Password (default: $DEFAULT_PASSWORD): ")" PASSWORD
        echo
        PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"
        if [[ -n "$PASSWORD" ]]; then
            break
        else
            print_status "ERROR" "Password cannot be empty"
        fi
    done

    # Disk size
    while true; do
        read -rp "$(print_status "INPUT" "Disk size (default: 20G): ")" DISK_SIZE
        DISK_SIZE="${DISK_SIZE:-20G}"
        if validate_input "size" "$DISK_SIZE"; then break; fi
    done

    # Memory
    while true; do
        read -rp "$(print_status "INPUT" "Memory in MB (default: 2048): ")" MEMORY
        MEMORY="${MEMORY:-2048}"
        if validate_input "number" "$MEMORY"; then break; fi
    done

    # CPUs
    while true; do
        read -rp "$(print_status "INPUT" "Number of CPUs (default: 2): ")" CPUS
        CPUS="${CPUS:-2}"
        if validate_input "number" "$CPUS"; then break; fi
    done

    # SSH Port
    while true; do
        read -rp "$(print_status "INPUT" "SSH host port (default: 2222): ")" SSH_PORT
        SSH_PORT="${SSH_PORT:-2222}"
        if validate_input "port" "$SSH_PORT"; then
            # Check host port availability
            if command -v ss &>/dev/null && ss -tln 2>/dev/null | grep -q ":${SSH_PORT} "; then
                print_status "ERROR" "Port $SSH_PORT is already in use on the host"
            # Also check no other VM config uses this port
            elif grep -rl "SSH_PORT=\"${SSH_PORT}\"" "$VM_DIR" 2>/dev/null | grep -q '.conf'; then
                print_status "ERROR" "Port $SSH_PORT is already used by another VM config"
            else
                break
            fi
        fi
    done

    # GUI Mode
    while true; do
        read -rp "$(print_status "INPUT" "Enable GUI mode? (y/n, default: n): ")" gui_input
        gui_input="${gui_input:-n}"
        if [[ "$gui_input" =~ ^[Yy]$ ]]; then
            GUI_MODE=true; break
        elif [[ "$gui_input" =~ ^[Nn]$ ]]; then
            GUI_MODE=false; break
        else
            print_status "ERROR" "Please answer y or n"
        fi
    done

    # Additional port forwards
    read -rp "$(print_status "INPUT" "Extra port forwards host:guest, comma-separated (e.g. 8080:80 — Enter for none): ")" PORT_FORWARDS

    IMG_FILE="$VM_DIR/$VM_NAME.img"
    SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"
    CREATED="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    setup_vm_image
    save_vm_config
}

# ---------------------------------------------------------------------------
# Start VM
# FIX #6: port forwarding — all forwards on the same netdev via multiple hostfwd=
# ---------------------------------------------------------------------------
start_vm() {
    local vm_name=$1

    if ! load_vm_config "$vm_name"; then
        return 1
    fi

    # Check image lock
    if ! check_image_lock "$IMG_FILE" "$vm_name"; then
        print_status "ERROR" "Cannot start VM: image file is locked"
        read -rp "$(print_status "INPUT" "Force-kill all QEMU processes using this image? (y/N): ")" force_kill
        if [[ "$force_kill" =~ ^[Yy]$ ]]; then
            pkill -f "qemu-system.*${IMG_FILE}" 2>/dev/null || true
            sleep 2
            pkill -9 -f "qemu-system.*${IMG_FILE}" 2>/dev/null || true
            rm -f "${IMG_FILE}.lock" 2>/dev/null || true
            print_status "SUCCESS" "Terminated processes using the image"
        else
            return 1
        fi
    fi

    # Check if already running
    if is_vm_running "$vm_name"; then
        print_status "WARN" "VM '$vm_name' is already running"
        read -rp "$(print_status "INPUT" "Stop and restart? (y/N): ")" restart_choice
        if [[ "$restart_choice" =~ ^[Yy]$ ]]; then
            stop_vm "$vm_name"
            sleep 2
        else
            return 1
        fi
    fi

    if [[ ! -f "$IMG_FILE" ]]; then
        print_status "ERROR" "VM image file not found: $IMG_FILE"
        return 1
    fi

    if [[ ! -f "$SEED_FILE" ]]; then
        print_status "WARN" "Seed file not found — recreating cloud-init image..."
        setup_vm_image
    fi

    # Detect acceleration
    local accel
    accel=$(detect_accel)
    local cpu_model="qemu64"
    if [[ "$accel" == "kvm" ]]; then
        cpu_model="host"
        print_status "SUCCESS" "KVM available — using hardware acceleration"
    else
        print_status "WARN" "KVM not available — using software emulation (TCG). Performance will be limited."
    fi

    print_status "INFO" "Starting VM: $vm_name"
    print_status "INFO" "SSH:      ssh -p $SSH_PORT ${USERNAME}@localhost"
    print_status "INFO" "Password: $PASSWORD"

    # -----------
    # FIX: Build netdev string with ALL hostfwd entries on n0 (single NIC)
    # -----------
    local netdev_str="user,id=n0,hostfwd=tcp::${SSH_PORT}-:22"
    if [[ -n "$PORT_FORWARDS" ]]; then
        IFS=',' read -ra forwards <<< "$PORT_FORWARDS"
        for fwd in "${forwards[@]}"; do
            fwd="${fwd// /}"   # trim spaces
            if [[ "$fwd" =~ ^([0-9]+):([0-9]+)$ ]]; then
                netdev_str+=",hostfwd=tcp::${BASH_REMATCH[1]}-:${BASH_REMATCH[2]}"
                print_status "INFO" "Port forward: host ${BASH_REMATCH[1]} → guest ${BASH_REMATCH[2]}"
            else
                print_status "WARN" "Skipping malformed port forward: '$fwd' (expected host:guest)"
            fi
        done
    fi

    local qemu_cmd=(
        qemu-system-x86_64
        -name "$vm_name"
        -m "$MEMORY"
        -smp "cpus=${CPUS}"
        -cpu "$cpu_model"
        -machine "type=pc,accel=${accel}"
        -drive "file=${IMG_FILE},format=qcow2,if=virtio,discard=unmap"
        -drive "file=${SEED_FILE},format=raw,if=virtio,readonly=on"
        -boot order=c
        -device virtio-net-pci,netdev=n0
        -netdev "$netdev_str"
        -device virtio-balloon-pci
        -object "rng-random,filename=/dev/urandom,id=rng0"
        -device virtio-rng-pci,rng=rng0
        -rtc base=utc,clock=host
    )

    # -no-hpet was removed in QEMU 8.x; add it only on older versions
    local qemu_ver
    qemu_ver=$(qemu-system-x86_64 --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1)
    local qemu_major=${qemu_ver%%.*}
    if (( qemu_major < 8 )); then
        qemu_cmd+=(-no-hpet)
    fi

    if [[ "$GUI_MODE" == true ]]; then
        qemu_cmd+=(-vga virtio -display gtk,gl=on)
        print_status "INFO" "Starting in GUI mode..."
    else
        qemu_cmd+=(-nographic -serial mon:stdio)
        print_status "INFO" "Starting in console mode — press Ctrl+A then X to exit QEMU"
    fi

    echo "Configuration: ${MEMORY}MB RAM | ${CPUS} vCPU(s) | ${DISK_SIZE} disk | accel=${accel}"

    if ! "${qemu_cmd[@]}"; then
        print_status "ERROR" "QEMU exited with an error. Check the image and configuration."
        rm -f "${IMG_FILE}.lock" 2>/dev/null || true
        return 1
    fi

    print_status "INFO" "VM $vm_name has stopped"
}

# ---------------------------------------------------------------------------
# Stop VM
# ---------------------------------------------------------------------------
stop_vm() {
    local vm_name=$1

    if ! load_vm_config "$vm_name"; then
        return 1
    fi

    if is_vm_running "$vm_name"; then
        print_status "INFO" "Stopping VM: $vm_name"

        pkill -SIGTERM -f "qemu-system.*${IMG_FILE}" 2>/dev/null || true
        sleep 3

        if is_vm_running "$vm_name"; then
            print_status "WARN" "VM did not stop gracefully — forcing termination..."
            pkill -9 -f "qemu-system.*${IMG_FILE}" 2>/dev/null || true
            sleep 1
        fi

        rm -f "${IMG_FILE}.lock" 2>/dev/null || true

        if is_vm_running "$vm_name"; then
            print_status "ERROR" "Failed to stop VM '$vm_name'"
            return 1
        else
            print_status "SUCCESS" "VM '$vm_name' stopped"
        fi
    else
        print_status "INFO" "VM '$vm_name' is not running"
        rm -f "${IMG_FILE}.lock" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Delete VM
# ---------------------------------------------------------------------------
delete_vm() {
    local vm_name=$1

    print_status "WARN" "⚠️  This will PERMANENTLY delete VM '$vm_name' and all its data!"
    read -rp "$(print_status "INPUT" "Type the VM name to confirm deletion: ")" confirm_name
    if [[ "$confirm_name" != "$vm_name" ]]; then
        print_status "INFO" "Deletion cancelled (name did not match)"
        return 0
    fi

    if ! load_vm_config "$vm_name"; then
        return 1
    fi

    if is_vm_running "$vm_name"; then
        print_status "WARN" "VM is running — stopping it first..."
        stop_vm "$vm_name"
        sleep 2
    fi

    rm -f "$IMG_FILE" "$SEED_FILE" "$VM_DIR/$vm_name.conf" "${IMG_FILE}.lock" 2>/dev/null || true
    print_status "SUCCESS" "VM '$vm_name' deleted"
}

# ---------------------------------------------------------------------------
# Show VM info
# FIX #7: use check_image_lock_silent (non-interactive) here
# ---------------------------------------------------------------------------
show_vm_info() {
    local vm_name=$1

    if ! load_vm_config "$vm_name"; then
        return 1
    fi

    echo
    print_status "INFO" "VM Information: $vm_name"
    echo "══════════════════════════════════════════════"
    printf "  %-16s %s\n" "OS:"         "$OS_TYPE ($CODENAME)"
    printf "  %-16s %s\n" "Hostname:"   "$HOSTNAME"
    printf "  %-16s %s\n" "Username:"   "$USERNAME"
    printf "  %-16s %s\n" "Password:"   "$PASSWORD"
    printf "  %-16s %s\n" "SSH Port:"   "$SSH_PORT"
    printf "  %-16s %s MB\n" "Memory:"  "$MEMORY"
    printf "  %-16s %s vCPU(s)\n" "CPUs:" "$CPUS"
    printf "  %-16s %s\n" "Disk:"       "$DISK_SIZE"
    printf "  %-16s %s\n" "GUI Mode:"   "$GUI_MODE"
    printf "  %-16s %s\n" "Fwd Ports:"  "${PORT_FORWARDS:-None}"
    printf "  %-16s %s\n" "Created:"    "$CREATED"
    printf "  %-16s %s\n" "Image:"      "$IMG_FILE"
    printf "  %-16s %s\n" "Seed:"       "$SEED_FILE"

    # Non-interactive lock check
    if check_image_lock_silent "$IMG_FILE"; then
        printf "  %-16s %s\n" "Image Lock:" "Unlocked"
    else
        printf "  %-16s %s\n" "Image Lock:" "Locked (possibly in use)"
    fi

    if is_vm_running "$vm_name"; then
        printf "  %-16s %s\n" "Status:" "🚀 Running"
        printf "  %-16s %s\n" "Connect:" "ssh -p ${SSH_PORT} ${USERNAME}@localhost"
    else
        printf "  %-16s %s\n" "Status:" "💤 Stopped"
    fi
    echo "══════════════════════════════════════════════"
    echo
    read -rp "$(print_status "INPUT" "Press Enter to continue...")"
}

# ---------------------------------------------------------------------------
# Edit VM config
# FIX #8: option 9 (disk size) now actually resizes the disk
# ---------------------------------------------------------------------------
edit_vm_config() {
    local vm_name=$1

    if ! load_vm_config "$vm_name"; then
        return 1
    fi

    print_status "INFO" "Editing VM: $vm_name"

    while true; do
        echo
        echo "  1) Hostname"
        echo "  2) Username"
        echo "  3) Password"
        echo "  4) SSH Port"
        echo "  5) GUI Mode"
        echo "  6) Port Forwards"
        echo "  7) Memory (RAM)"
        echo "  8) CPU Count"
        echo "  9) Disk Size (resizes the image)"
        echo "  0) Back"

        read -rp "$(print_status "INPUT" "Enter your choice: ")" edit_choice

        case $edit_choice in
            1)
                while true; do
                    read -rp "$(print_status "INPUT" "New hostname (current: $HOSTNAME): ")" v
                    v="${v:-$HOSTNAME}"
                    if validate_input "name" "$v"; then HOSTNAME="$v"; break; fi
                done
                ;;
            2)
                while true; do
                    read -rp "$(print_status "INPUT" "New username (current: $USERNAME): ")" v
                    v="${v:-$USERNAME}"
                    if validate_input "username" "$v"; then USERNAME="$v"; break; fi
                done
                ;;
            3)
                while true; do
                    read -rsp "$(print_status "INPUT" "New password (leave blank to keep current): ")" v; echo
                    v="${v:-$PASSWORD}"
                    if [[ -n "$v" ]]; then PASSWORD="$v"; break; fi
                    print_status "ERROR" "Password cannot be empty"
                done
                ;;
            4)
                while true; do
                    read -rp "$(print_status "INPUT" "New SSH port (current: $SSH_PORT): ")" v
                    v="${v:-$SSH_PORT}"
                    if validate_input "port" "$v"; then
                        if [[ "$v" != "$SSH_PORT" ]] && command -v ss &>/dev/null && ss -tln | grep -q ":${v} "; then
                            print_status "ERROR" "Port $v is in use on the host"
                        else
                            SSH_PORT="$v"; break
                        fi
                    fi
                done
                ;;
            5)
                while true; do
                    read -rp "$(print_status "INPUT" "Enable GUI mode? (y/n, current: $GUI_MODE): ")" v
                    if [[ -z "$v" ]]; then break
                    elif [[ "$v" =~ ^[Yy]$ ]]; then GUI_MODE=true; break
                    elif [[ "$v" =~ ^[Nn]$ ]]; then GUI_MODE=false; break
                    else print_status "ERROR" "Please answer y or n"; fi
                done
                ;;
            6)
                read -rp "$(print_status "INPUT" "Port forwards (current: ${PORT_FORWARDS:-None}): ")" v
                PORT_FORWARDS="${v:-$PORT_FORWARDS}"
                ;;
            7)
                while true; do
                    read -rp "$(print_status "INPUT" "Memory in MB (current: $MEMORY): ")" v
                    v="${v:-$MEMORY}"
                    if validate_input "number" "$v"; then MEMORY="$v"; break; fi
                done
                ;;
            8)
                while true; do
                    read -rp "$(print_status "INPUT" "CPU count (current: $CPUS): ")" v
                    v="${v:-$CPUS}"
                    if validate_input "number" "$v"; then CPUS="$v"; break; fi
                done
                ;;
            9)
                # FIX: actually resize the disk image
                if is_vm_running "$vm_name"; then
                    print_status "ERROR" "Stop the VM before resizing its disk."
                else
                    while true; do
                        read -rp "$(print_status "INPUT" "New disk size (current: $DISK_SIZE): ")" v
                        v="${v:-$DISK_SIZE}"
                        if validate_input "size" "$v"; then
                            if [[ "$v" == "$DISK_SIZE" ]]; then
                                print_status "INFO" "Size unchanged."; break
                            fi
                            print_status "INFO" "Resizing disk to $v ..."
                            if qemu-img resize "$IMG_FILE" "$v"; then
                                DISK_SIZE="$v"
                                print_status "SUCCESS" "Disk resized to $v"
                            else
                                print_status "ERROR" "qemu-img resize failed"
                            fi
                            break
                        fi
                    done
                fi
                ;;
            0) return 0 ;;
            *) print_status "ERROR" "Invalid selection"; continue ;;
        esac

        # Rebuild cloud-init seed if credentials/hostname changed
        if [[ "$edit_choice" =~ ^[123]$ ]]; then
            print_status "INFO" "Updating cloud-init seed image..."
            setup_vm_image
        fi

        save_vm_config

        read -rp "$(print_status "INPUT" "Continue editing? (y/N): ")" cont
        [[ "$cont" =~ ^[Yy]$ ]] || break
    done
}

# ---------------------------------------------------------------------------
# Resize VM disk (standalone menu action)
# ---------------------------------------------------------------------------
resize_vm_disk() {
    local vm_name=$1

    if ! load_vm_config "$vm_name"; then
        return 1
    fi

    if is_vm_running "$vm_name"; then
        print_status "ERROR" "Cannot resize disk while VM is running. Stop it first."
        return 1
    fi

    print_status "INFO" "Current disk size: $DISK_SIZE"

    while true; do
        read -rp "$(print_status "INPUT" "New disk size (e.g., 50G): ")" new_size
        if ! validate_input "size" "$new_size"; then continue; fi

        if [[ "$new_size" == "$DISK_SIZE" ]]; then
            print_status "INFO" "No change."; return 0
        fi

        # Warn on shrink
        local cur_mb new_mb
        cur_mb=${DISK_SIZE%[GgMm]}
        new_mb=${new_size%[GgMm]}
        [[ "${DISK_SIZE: -1}" =~ [Gg] ]] && cur_mb=$((cur_mb * 1024))
        [[ "${new_size: -1}" =~ [Gg] ]] && new_mb=$((new_mb * 1024))

        if (( new_mb < cur_mb )); then
            print_status "WARN" "Shrinking a disk can cause DATA LOSS and filesystem corruption!"
            read -rp "$(print_status "INPUT" "Continue anyway? (y/N): ")" confirm
            [[ "$confirm" =~ ^[Yy]$ ]] || { print_status "INFO" "Cancelled."; return 0; }
        fi

        print_status "INFO" "Resizing disk to $new_size ..."
        if qemu-img resize "$IMG_FILE" "$new_size"; then
            DISK_SIZE="$new_size"
            save_vm_config
            print_status "SUCCESS" "Disk resized to $new_size"
        else
            print_status "ERROR" "Failed to resize disk"
            return 1
        fi
        break
    done
}

# ---------------------------------------------------------------------------
# Performance metrics
# ---------------------------------------------------------------------------
show_vm_performance() {
    local vm_name=$1

    if ! load_vm_config "$vm_name"; then
        return 1
    fi

    echo
    print_status "INFO" "Performance metrics: $vm_name"
    echo "══════════════════════════════════════"

    if is_vm_running "$vm_name"; then
        local qemu_pid
        qemu_pid=$(pgrep -f "qemu-system.*${IMG_FILE}" | head -1)

        if [[ -n "$qemu_pid" ]]; then
            echo "QEMU Process Stats (PID $qemu_pid):"
            ps -p "$qemu_pid" -o pid,pcpu,pmem,rss,vsz,stat --no-headers
            echo

            echo "Host Memory Overview:"
            free -h
            echo

            echo "Image File Disk Usage:"
            du -h "$IMG_FILE" 2>/dev/null || echo "  (file not found)"
        else
            print_status "ERROR" "Could not find QEMU process for VM $vm_name"
        fi
    else
        print_status "INFO" "VM '$vm_name' is not running"
        echo "  Allocated memory : ${MEMORY} MB"
        echo "  Allocated CPUs   : ${CPUS}"
        echo "  Disk size        : ${DISK_SIZE}"
        echo "  Image file       : $(du -h "$IMG_FILE" 2>/dev/null | cut -f1) used on disk"
    fi

    echo "══════════════════════════════════════"
    read -rp "$(print_status "INPUT" "Press Enter to continue...")"
}

# ---------------------------------------------------------------------------
# Fix VM issues
# ---------------------------------------------------------------------------
fix_vm_issues() {
    local vm_name=$1

    if ! load_vm_config "$vm_name"; then
        return 1
    fi

    print_status "INFO" "Fixing issues for VM: $vm_name"
    echo
    echo "  1) Remove lock files"
    echo "  2) Recreate seed (cloud-init) image"
    echo "  3) Re-save configuration file"
    echo "  4) Kill stuck QEMU processes"
    echo "  5) Check image integrity (qemu-img check)"
    echo "  0) Back"

    read -rp "$(print_status "INPUT" "Enter your choice: ")" fix_choice

    case $fix_choice in
        1)
            rm -f "${IMG_FILE}.lock" "${IMG_FILE}"*.lock 2>/dev/null || true
            print_status "SUCCESS" "Lock files removed"
            ;;
        2)
            rm -f "$SEED_FILE"
            setup_vm_image
            print_status "SUCCESS" "Seed image recreated"
            ;;
        3)
            save_vm_config
            print_status "SUCCESS" "Configuration re-saved"
            ;;
        4)
            if pkill -f "qemu-system.*${IMG_FILE}" 2>/dev/null; then
                sleep 1
                pkill -9 -f "qemu-system.*${IMG_FILE}" 2>/dev/null || true
                print_status "SUCCESS" "Killed stuck QEMU processes"
            else
                print_status "INFO" "No stuck processes found"
            fi
            ;;
        5)
            print_status "INFO" "Checking image integrity (this may take a moment)..."
            if qemu-img check "$IMG_FILE"; then
                print_status "SUCCESS" "Image is healthy"
            else
                print_status "WARN" "Image has errors — consider recreating or restoring from backup"
            fi
            ;;
        0)
            return 0
            ;;
        *)
            print_status "ERROR" "Invalid selection"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        display_header

        local vms=()
        mapfile -t vms < <(get_vm_list)
        local vm_count=${#vms[@]}

        if (( vm_count > 0 )); then
            print_status "INFO" "Found $vm_count existing VM(s):"
            local i
            for i in "${!vms[@]}"; do
                local status_icon="💤"
                if is_vm_running "${vms[$i]}"; then
                    status_icon="🚀"
                fi
                printf "  %2d) %-20s %s\n" "$((i + 1))" "${vms[$i]}" "$status_icon"
            done
            echo
        fi

        echo "Main Menu:"
        echo "  1) Create a new VM"
        if (( vm_count > 0 )); then
            echo "  2) Start a VM"
            echo "  3) Stop a VM"
            echo "  4) Show VM info"
            echo "  5) Edit VM configuration"
            echo "  6) Delete a VM"
            echo "  7) Resize VM disk"
            echo "  8) Show VM performance"
            echo "  9) Fix VM issues"
        fi
        echo "  0) Exit"
        echo

        read -rp "$(print_status "INPUT" "Enter your choice: ")" choice

        # Helper: prompt for VM number and return index
        pick_vm() {
            local action=$1
            local vm_num
            read -rp "$(print_status "INPUT" "Enter VM number to $action: ")" vm_num
            if [[ "$vm_num" =~ ^[0-9]+$ ]] && (( vm_num >= 1 && vm_num <= vm_count )); then
                echo $(( vm_num - 1 ))
                return 0
            else
                print_status "ERROR" "Invalid selection"
                return 1
            fi
        }

        case $choice in
            1)
                create_new_vm
                ;;
            2)
                if (( vm_count > 0 )); then
                    local idx; idx=$(pick_vm "start") && start_vm "${vms[$idx]}"
                fi
                ;;
            3)
                if (( vm_count > 0 )); then
                    local idx; idx=$(pick_vm "stop") && stop_vm "${vms[$idx]}"
                fi
                ;;
            4)
                if (( vm_count > 0 )); then
                    local idx; idx=$(pick_vm "inspect") && show_vm_info "${vms[$idx]}"
                fi
                ;;
            5)
                if (( vm_count > 0 )); then
                    local idx; idx=$(pick_vm "edit") && edit_vm_config "${vms[$idx]}"
                fi
                ;;
            6)
                if (( vm_count > 0 )); then
                    local idx; idx=$(pick_vm "delete") && delete_vm "${vms[$idx]}"
                fi
                ;;
            7)
                if (( vm_count > 0 )); then
                    local idx; idx=$(pick_vm "resize disk of") && resize_vm_disk "${vms[$idx]}"
                fi
                ;;
            8)
                if (( vm_count > 0 )); then
                    local idx; idx=$(pick_vm "show performance of") && show_vm_performance "${vms[$idx]}"
                fi
                ;;
            9)
                if (( vm_count > 0 )); then
                    local idx; idx=$(pick_vm "fix") && fix_vm_issues "${vms[$idx]}"
                fi
                ;;
            0)
                print_status "INFO" "Goodbye!"
                exit 0
                ;;
            *)
                print_status "ERROR" "Invalid option"
                ;;
        esac

        read -rp "$(print_status "INPUT" "Press Enter to continue...")"
    done
}

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------

# Check dependencies first
check_dependencies

# Set VM directory (can be overridden via env)
VM_DIR="${VM_DIR:-$HOME/vms}"
mkdir -p "$VM_DIR"

# Supported OS list
declare -A OS_OPTIONS=(
    ["Ubuntu 22.04 LTS"]="ubuntu|jammy|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|ubuntu22|ubuntu|ubuntu"
    ["Ubuntu 24.04 LTS"]="ubuntu|noble|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu24|ubuntu|ubuntu"
    ["Ubuntu 24.10"]="ubuntu|oracular|https://cloud-images.ubuntu.com/oracular/current/oracular-server-cloudimg-amd64.img|ubuntu2410|ubuntu|ubuntu"
    ["Debian 11 (Bullseye)"]="debian|bullseye|https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2|debian11|debian|debian"
    ["Debian 12 (Bookworm)"]="debian|bookworm|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2|debian12|debian|debian"
    ["Debian 13 (Trixie)"]="debian|trixie|https://cloud.debian.org/images/cloud/trixie/daily/latest/debian-13-generic-amd64-daily.qcow2|debian13|debian|debian"
    ["Fedora 40"]="fedora|40|https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-40-1.14.x86_64.qcow2|fedora40|fedora|fedora"
    ["Fedora 41"]="fedora|41|https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-41-1.4.x86_64.qcow2|fedora41|fedora|fedora"
    ["CentOS Stream 9"]="centos|stream9|https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2|centos9|centos|centos"
    ["AlmaLinux 9"]="almalinux|9|https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2|almalinux9|alma|alma"
    ["Rocky Linux 9"]="rockylinux|9|https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2|rocky9|rocky|rocky"
)

# Start
main_menu
