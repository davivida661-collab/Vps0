#!/bin/bash
set -euo pipefail

# =============================
# Enhanced Multi-VM Manager (Pure QEMU Version)
# Version 2.0 - Improved & Fixed
# =============================

# ─── Constants ────────────────────────────────────────────────────────────────
SCRIPT_VERSION="2.0"
VM_DIR="${VM_DIR:-$HOME/vms}"
LOG_FILE="${VM_DIR}/vm-manager.log"
QEMU_TIMEOUT=10  # seconds to wait for graceful shutdown

# ─── Ordered OS list (parallel arrays to preserve menu order) ─────────────────
OS_NAMES=(
    "Ubuntu 22.04 LTS (Jammy)"
    "Ubuntu 24.04 LTS (Noble)"
    "Debian 11 (Bullseye)"
    "Debian 12 (Bookworm)"
    "Debian 13 (Trixie, daily)"
    "Fedora 40"
    "CentOS Stream 9"
    "AlmaLinux 9"
    "Rocky Linux 9"
)
OS_TYPES=(ubuntu  ubuntu  debian  debian  debian  fedora  centos  almalinux  rockylinux)
OS_CODENAMES=(jammy noble bullseye bookworm trixie 40 stream9 9 9)
OS_URLS=(
    "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
    "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    "https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2"
    "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
    "https://cloud.debian.org/images/cloud/trixie/daily/latest/debian-13-generic-amd64-daily.qcow2"
    "https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-40-1.14.x86_64.qcow2"
    "https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2"
    "https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"
    "https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2"
)
OS_DEFAULT_USERS=(ubuntu ubuntu debian debian debian fedora centos almalinux rocky)
OS_DEFAULT_PASSWORDS=(ubuntu ubuntu debian debian debian fedora centos almalinux rocky)

# ─── Logging ──────────────────────────────────────────────────────────────────
log() {
    mkdir -p "$VM_DIR"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true
}

# ─── Display ──────────────────────────────────────────────────────────────────
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
                                                          v${SCRIPT_VERSION}
EOF
    echo
}

print_status() {
    local type=$1
    local message=$2
    local ts
    ts="$(date '+%H:%M:%S')"
    case $type in
        "INFO")    echo -e "\033[1;34m[${ts}] 📋 [INFO]\033[0m    $message" ;;
        "WARN")    echo -e "\033[1;33m[${ts}] ⚠️  [WARN]\033[0m    $message" ;;
        "ERROR")   echo -e "\033[1;31m[${ts}] ❌ [ERROR]\033[0m   $message" ;;
        "SUCCESS") echo -e "\033[1;32m[${ts}] ✅ [SUCCESS]\033[0m $message" ;;
        "INPUT")   echo -e "\033[1;36m🎯 [INPUT]\033[0m $message" ;;
        *)         echo "[$type] $message" ;;
    esac
    log "$type: $message"
}

separator() { echo -e "\033[1;90m────────────────────────────────────────────────────────\033[0m"; }

# ─── Input validation ─────────────────────────────────────────────────────────
validate_input() {
    local type=$1
    local value=$2
    case $type in
        "number")
            [[ "$value" =~ ^[0-9]+$ ]] || { print_status "ERROR" "Must be a positive integer"; return 1; } ;;
        "size")
            [[ "$value" =~ ^[0-9]+[GgMm]$ ]] || { print_status "ERROR" "Must be a size with unit (e.g. 100G, 512M)"; return 1; } ;;
        "port")
            [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 23 ] && [ "$value" -le 65535 ] \
                || { print_status "ERROR" "Must be a valid port (23-65535)"; return 1; } ;;
        "name")
            [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]] \
                || { print_status "ERROR" "Only letters, numbers, hyphens, and underscores allowed"; return 1; } ;;
        "username")
            [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]] \
                || { print_status "ERROR" "Must start with a letter/underscore; only lowercase letters, numbers, hyphens, underscores"; return 1; } ;;
    esac
    return 0
}

# ─── Dependencies ─────────────────────────────────────────────────────────────
check_dependencies() {
    local deps=("qemu-system-x86_64" "wget" "cloud-localds" "qemu-img" "lsof" "openssl" "socat")
    local missing=()

    for dep in "${deps[@]}"; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done

    if [ ${#missing[@]} -ne 0 ]; then
        print_status "ERROR" "Missing dependencies: ${missing[*]}"
        echo
        echo "  Install on Ubuntu/Debian:  sudo apt install qemu-system cloud-image-utils wget lsof openssl socat"
        echo "  Install on Fedora:         sudo dnf install qemu-system-x86 cloud-utils wget lsof openssl socat"
        echo "  Install on Arch:           sudo pacman -S qemu-full cloud-image-utils wget lsof openssl socat"
        exit 1
    fi
}

# ─── Cleanup ──────────────────────────────────────────────────────────────────
cleanup() {
    rm -f /tmp/vm-manager-user-data-$$ /tmp/vm-manager-meta-data-$$ 2>/dev/null || true
}
trap cleanup EXIT

# ─── VM directory & files ────────────────────────────────────────────────────
vm_img_file()    { echo "$VM_DIR/$1.img"; }
vm_seed_file()   { echo "$VM_DIR/$1-seed.iso"; }
vm_conf_file()   { echo "$VM_DIR/$1.conf"; }
vm_pid_file()    { echo "$VM_DIR/$1.pid"; }
vm_monitor_file(){ echo "$VM_DIR/$1.monitor"; }
vm_log_file()    { echo "$VM_DIR/$1.log"; }
vm_vnc_file()    { echo "$VM_DIR/$1.vnc"; }  # stores VNC port

# ─── VM list & config ────────────────────────────────────────────────────────
get_vm_list() {
    find "$VM_DIR" -maxdepth 1 -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort
}

load_vm_config() {
    local vm_name=$1
    local conf
    conf="$(vm_conf_file "$vm_name")"

    if [[ -f "$conf" ]]; then
        # Unset all config vars to avoid stale data
        unset VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD \
              DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE VNC_MODE VNC_PORT \
              PORT_FORWARDS IMG_FILE SEED_FILE CREATED SSH_KEY

        # shellcheck disable=SC1090
        source "$conf"
        # Backward compat: ensure new fields have defaults
        VNC_MODE="${VNC_MODE:-false}"
        VNC_PORT="${VNC_PORT:-}"
        SSH_KEY="${SSH_KEY:-}"
        PORT_FORWARDS="${PORT_FORWARDS:-}"
        return 0
    else
        print_status "ERROR" "Configuration for VM '$vm_name' not found"
        return 1
    fi
}

save_vm_config() {
    local conf
    conf="$(vm_conf_file "$VM_NAME")"

    cat > "$conf" << EOF
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
GUI_MODE="${GUI_MODE:-false}"
VNC_MODE="${VNC_MODE:-false}"
VNC_PORT="${VNC_PORT:-}"
PORT_FORWARDS="${PORT_FORWARDS:-}"
SSH_KEY="${SSH_KEY:-}"
IMG_FILE="$IMG_FILE"
SEED_FILE="$SEED_FILE"
CREATED="$CREATED"
EOF
    print_status "SUCCESS" "Configuration saved"
}

# ─── Process / running status ─────────────────────────────────────────────────

# BUG FIX: original function called load_vm_config inside is_vm_running,
# which wiped all global VM variables mid-operation. Now we accept the
# pid/img path directly or look them up from the pidfile without re-loading.
is_vm_running() {
    local vm_name=$1
    local pid_file
    pid_file="$(vm_pid_file "$vm_name")"

    # Primary check: pidfile
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        else
            # Stale pidfile
            rm -f "$pid_file"
        fi
    fi

    # Fallback: pgrep by VM name pattern
    if pgrep -f "qemu-system.*${vm_name}" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

get_vm_pid() {
    local vm_name=$1
    local pid_file
    pid_file="$(vm_pid_file "$vm_name")"
    if [[ -f "$pid_file" ]]; then
        cat "$pid_file" 2>/dev/null
    else
        pgrep -f "qemu-system.*${vm_name}" 2>/dev/null | head -1
    fi
}

# ─── Image lock check (non-interactive version for status display) ────────────
is_image_locked() {
    local img_file=$1
    lsof "$img_file" 2>/dev/null | grep -q qemu-system
}

check_image_lock() {
    local img_file=$1
    local vm_name=$2

    if lsof "$img_file" 2>/dev/null | grep -q qemu-system; then
        print_status "WARN" "Image $img_file is already open by a QEMU process"
        local pid
        pid=$(lsof "$img_file" 2>/dev/null | awk '/qemu-system/{print $2}' | head -1)
        if [[ -n "$pid" ]]; then
            print_status "INFO" "Process using image: PID $pid"
            if ps -p "$pid" -o cmd= 2>/dev/null | grep -q "$vm_name"; then
                print_status "INFO" "This looks like the same VM already running"
                read -rp "$(print_status "INPUT" "Kill existing process and restart? (y/N): ")" kill_choice
                if [[ "$kill_choice" =~ ^[Yy]$ ]]; then
                    kill "$pid" 2>/dev/null
                    sleep 2
                    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
                    rm -f "$(vm_pid_file "$vm_name")"
                    return 0
                fi
            else
                print_status "ERROR" "A different QEMU instance is using this image"
            fi
        fi
        return 1
    fi
    return 0
}

# ─── Port conflict detection (checks both system + existing VM configs) ────────
is_port_in_use() {
    local port=$1
    local exclude_vm="${2:-}"

    # System-level check
    if ss -tln 2>/dev/null | grep -qE ":${port}\b"; then
        return 0
    fi

    # Check all other VM configs to avoid double-booking
    while IFS= read -r vm; do
        [[ "$vm" == "$exclude_vm" ]] && continue
        local conf
        conf="$(vm_conf_file "$vm")"
        if grep -q "SSH_PORT=\"$port\"" "$conf" 2>/dev/null; then
            return 0
        fi
    done < <(get_vm_list)
    return 1
}

# ─── Cloud-init seed creation (separated from image download) ─────────────────
create_seed_image() {
    local tmp_ud="/tmp/vm-manager-user-data-$$"
    local tmp_md="/tmp/vm-manager-meta-data-$$"

    print_status "INFO" "Generating cloud-init seed..."

    # Hash the password
    local hashed_pass
    hashed_pass=$(openssl passwd -6 "$PASSWORD") || {
        print_status "ERROR" "Failed to hash password"
        return 1
    }

    # Build user-data
    cat > "$tmp_ud" << EOF
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
EOF

    # Inject SSH public key if provided
    if [[ -n "${SSH_KEY:-}" ]]; then
        cat >> "$tmp_ud" << EOF
    ssh_authorized_keys:
      - $SSH_KEY
EOF
    fi

    cat >> "$tmp_ud" << EOF
chpasswd:
  list: |
    root:$PASSWORD
    $USERNAME:$PASSWORD
  expire: false
package_update: false
runcmd:
  - systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true
EOF

    cat > "$tmp_md" << EOF
instance-id: iid-${VM_NAME}-$(date +%s)
local-hostname: $HOSTNAME
EOF

    if ! cloud-localds "$SEED_FILE" "$tmp_ud" "$tmp_md"; then
        print_status "ERROR" "Failed to create cloud-init seed image"
        rm -f "$tmp_ud" "$tmp_md"
        return 1
    fi

    rm -f "$tmp_ud" "$tmp_md"
    print_status "SUCCESS" "Seed image created: $SEED_FILE"
}

# ─── Image download & resize ──────────────────────────────────────────────────
download_vm_image() {
    mkdir -p "$VM_DIR"

    if [[ -f "$IMG_FILE" ]]; then
        print_status "INFO" "Image already exists, skipping download"
    else
        print_status "INFO" "Downloading: $IMG_URL"
        if ! wget --progress=bar:force "$IMG_URL" -O "${IMG_FILE}.tmp"; then
            print_status "ERROR" "Download failed"
            rm -f "${IMG_FILE}.tmp"
            return 1
        fi
        mv "${IMG_FILE}.tmp" "$IMG_FILE"
        print_status "SUCCESS" "Image downloaded"
    fi

    # Resize to requested disk size
    local current_size
    current_size=$(qemu-img info --output=json "$IMG_FILE" 2>/dev/null | grep -o '"virtual-size":[0-9]*' | cut -d: -f2 || echo 0)
    local target_bytes
    local num unit
    num="${DISK_SIZE%[GgMm]}"
    unit="${DISK_SIZE: -1}"
    if [[ "$unit" =~ [Gg] ]]; then
        target_bytes=$((num * 1024 * 1024 * 1024))
    else
        target_bytes=$((num * 1024 * 1024))
    fi

    if [[ "$current_size" -lt "$target_bytes" ]] 2>/dev/null; then
        print_status "INFO" "Resizing disk to $DISK_SIZE..."
        if ! qemu-img resize "$IMG_FILE" "$DISK_SIZE"; then
            print_status "WARN" "Resize failed; creating a new qcow2 image at $DISK_SIZE"
            qemu-img create -f qcow2 "$IMG_FILE" "$DISK_SIZE"
        fi
    fi
}

# ─── Full VM setup (download + seed) ─────────────────────────────────────────
setup_vm_image() {
    download_vm_image || return 1
    create_seed_image || return 1
    print_status "SUCCESS" "VM '$VM_NAME' is ready"
    separator
    print_status "INFO" "Username : $USERNAME"
    print_status "INFO" "Password : $PASSWORD"
    print_status "INFO" "SSH      : ssh -p $SSH_PORT $USERNAME@localhost"
}

# ─── Create new VM ────────────────────────────────────────────────────────────
create_new_vm() {
    separator
    print_status "INFO" "Creating a new VM"
    separator

    # --- OS selection (ordered) ---
    echo
    echo "  Available operating systems:"
    echo
    for i in "${!OS_NAMES[@]}"; do
        printf "  \033[1;36m%2d)\033[0m %s\n" $((i+1)) "${OS_NAMES[$i]}"
    done
    echo

    local os_idx
    while true; do
        read -rp "$(print_status "INPUT" "Select OS (1-${#OS_NAMES[@]}): ")" os_idx
        if [[ "$os_idx" =~ ^[0-9]+$ ]] && [ "$os_idx" -ge 1 ] && [ "$os_idx" -le "${#OS_NAMES[@]}" ]; then
            os_idx=$((os_idx - 1))
            break
        fi
        print_status "ERROR" "Invalid selection"
    done

    OS_TYPE="${OS_TYPES[$os_idx]}"
    CODENAME="${OS_CODENAMES[$os_idx]}"
    IMG_URL="${OS_URLS[$os_idx]}"
    local default_user="${OS_DEFAULT_USERS[$os_idx]}"
    local default_pass="${OS_DEFAULT_PASSWORDS[$os_idx]}"

    separator
    # --- VM name ---
    while true; do
        read -rp "$(print_status "INPUT" "VM name [${OS_TYPE}vm]: ")" VM_NAME
        VM_NAME="${VM_NAME:-${OS_TYPE}vm}"
        if ! validate_input "name" "$VM_NAME"; then continue; fi
        if [[ -f "$(vm_conf_file "$VM_NAME")" ]]; then
            print_status "ERROR" "A VM named '$VM_NAME' already exists"
        else
            break
        fi
    done

    # --- Hostname ---
    while true; do
        read -rp "$(print_status "INPUT" "Hostname [$VM_NAME]: ")" HOSTNAME
        HOSTNAME="${HOSTNAME:-$VM_NAME}"
        validate_input "name" "$HOSTNAME" && break
    done

    # --- Username ---
    while true; do
        read -rp "$(print_status "INPUT" "Username [$default_user]: ")" USERNAME
        USERNAME="${USERNAME:-$default_user}"
        validate_input "username" "$USERNAME" && break
    done

    # --- Password ---
    while true; do
        read -rsp "$(print_status "INPUT" "Password [$default_pass]: ")" PASSWORD
        PASSWORD="${PASSWORD:-$default_pass}"
        echo
        [[ -n "$PASSWORD" ]] && break
        print_status "ERROR" "Password cannot be empty"
    done

    # --- SSH public key (optional) ---
    SSH_KEY=""
    read -rp "$(print_status "INPUT" "SSH public key to inject (paste key or press Enter to skip): ")" SSH_KEY

    # --- Disk size ---
    while true; do
        read -rp "$(print_status "INPUT" "Disk size [20G]: ")" DISK_SIZE
        DISK_SIZE="${DISK_SIZE:-20G}"
        validate_input "size" "$DISK_SIZE" && break
    done

    # --- Memory ---
    while true; do
        read -rp "$(print_status "INPUT" "RAM in MB [2048]: ")" MEMORY
        MEMORY="${MEMORY:-2048}"
        validate_input "number" "$MEMORY" && break
    done

    # --- CPUs ---
    while true; do
        read -rp "$(print_status "INPUT" "Number of CPUs [2]: ")" CPUS
        CPUS="${CPUS:-2}"
        validate_input "number" "$CPUS" && break
    done

    # --- SSH port ---
    while true; do
        read -rp "$(print_status "INPUT" "SSH port [2222]: ")" SSH_PORT
        SSH_PORT="${SSH_PORT:-2222}"
        if ! validate_input "port" "$SSH_PORT"; then continue; fi
        if is_port_in_use "$SSH_PORT"; then
            print_status "ERROR" "Port $SSH_PORT is already in use by another process or VM"
        else
            break
        fi
    done

    # --- Display mode ---
    GUI_MODE=false
    VNC_MODE=false
    VNC_PORT=""
    echo
    echo "  Display mode:"
    echo "  1) Headless (console / SSH only)"
    echo "  2) VNC     (remote desktop, works everywhere)"
    echo "  3) GTK     (local GUI window, needs a desktop)"
    echo
    local disp_choice
    while true; do
        read -rp "$(print_status "INPUT" "Display mode [1]: ")" disp_choice
        disp_choice="${disp_choice:-1}"
        case $disp_choice in
            1) break ;;
            2)
                VNC_MODE=true
                while true; do
                    read -rp "$(print_status "INPUT" "VNC display port (5900+N, e.g. 5901) [5900]: ")" VNC_PORT
                    VNC_PORT="${VNC_PORT:-5900}"
                    if ! validate_input "port" "$VNC_PORT"; then continue; fi
                    if is_port_in_use "$VNC_PORT"; then
                        print_status "ERROR" "Port $VNC_PORT is already in use"
                    else
                        break
                    fi
                done
                break ;;
            3)
                GUI_MODE=true
                break ;;
            *) print_status "ERROR" "Invalid selection" ;;
        esac
    done

    # --- Port forwards ---
    PORT_FORWARDS=""
    read -rp "$(print_status "INPUT" "Extra port forwards host:guest, comma-separated (e.g. 8080:80,3306:3306) or Enter for none: ")" PORT_FORWARDS

    IMG_FILE="$(vm_img_file "$VM_NAME")"
    SEED_FILE="$(vm_seed_file "$VM_NAME")"
    CREATED="$(date '+%Y-%m-%d %H:%M:%S')"

    setup_vm_image || return 1
    save_vm_config
}

# ─── Start VM ─────────────────────────────────────────────────────────────────
start_vm() {
    local vm_name=$1
    load_vm_config "$vm_name" || return 1

    # Check image lock (interactive)
    if ! check_image_lock "$IMG_FILE" "$vm_name"; then
        read -rp "$(print_status "INPUT" "Force-kill all QEMU processes using this image? (y/N): ")" fk
        if [[ "$fk" =~ ^[Yy]$ ]]; then
            pkill -f "qemu-system.*${IMG_FILE}" 2>/dev/null || true
            sleep 2
            pkill -9 -f "qemu-system.*${IMG_FILE}" 2>/dev/null || true
            rm -f "$(vm_pid_file "$vm_name")"
            print_status "SUCCESS" "Processes terminated"
        else
            return 1
        fi
    fi

    # Already running?
    if is_vm_running "$vm_name"; then
        print_status "WARN" "VM '$vm_name' is already running"
        read -rp "$(print_status "INPUT" "Stop and restart? (y/N): ")" rc
        if [[ "$rc" =~ ^[Yy]$ ]]; then
            stop_vm "$vm_name"
            sleep 2
        else
            return 1
        fi
    fi

    [[ -f "$IMG_FILE" ]] || { print_status "ERROR" "Image not found: $IMG_FILE"; return 1; }
    if [[ ! -f "$SEED_FILE" ]]; then
        print_status "WARN" "Seed file missing — recreating..."
        create_seed_image || return 1
    fi

    local monitor_sock pid_file log_out
    monitor_sock="$(vm_monitor_file "$vm_name")"
    pid_file="$(vm_pid_file "$vm_name")"
    log_out="$(vm_log_file "$vm_name")"

    separator
    print_status "INFO" "Starting VM: $vm_name"
    print_status "INFO" "RAM: ${MEMORY}MB | CPUs: $CPUS | Disk: $DISK_SIZE"
    print_status "INFO" "SSH: ssh -p $SSH_PORT $USERNAME@localhost"
    print_status "INFO" "Password: $PASSWORD"
    separator

    # ── Build QEMU command ───────────────────────────────────────────────────
    local qemu_cmd=(
        qemu-system-x86_64
        -name "$vm_name"
        -m "$MEMORY"
        -smp "$CPUS"
        -cpu qemu64
        -machine type=pc,accel=tcg

        # Main disk
        -drive "file=${IMG_FILE},format=qcow2,if=virtio,cache=writeback"
        # Cloud-init seed
        -drive "file=${SEED_FILE},format=raw,if=virtio,readonly=on"

        -boot order=c

        # Primary network (SSH forward)
        # BUG FIX: use a stable netdev id 'net0' instead of computed index
        -device virtio-net-pci,netdev=net0
        -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22"

        # QMP monitor socket for graceful shutdown & scripting
        -monitor "unix:${monitor_sock},server,nowait"

        # Virtio RNG (faster entropy)
        -object rng-random,filename=/dev/urandom,id=rng0
        -device virtio-rng-pci,rng=rng0

        # Better timekeeping
        -rtc base=utc,clock=host
        -no-hpet

        # Balloon driver for dynamic memory
        -device virtio-balloon-pci
    )

    # ── Additional port forwards ─────────────────────────────────────────────
    # BUG FIX: original code computed netdev id as ${#qemu_cmd[@]} but the
    # array size changes between the -device and -netdev additions, so the ids
    # never matched.  Use a dedicated counter instead.
    if [[ -n "${PORT_FORWARDS:-}" ]]; then
        local netdev_idx=1   # net0 is already used above
        IFS=',' read -ra forwards <<< "$PORT_FORWARDS"
        for forward in "${forwards[@]}"; do
            forward="${forward// /}"   # strip spaces
            IFS=':' read -r host_port guest_port <<< "$forward"
            if validate_input "port" "$host_port" 2>/dev/null && validate_input "port" "$guest_port" 2>/dev/null; then
                local nid="net${netdev_idx}"
                qemu_cmd+=(
                    -device "virtio-net-pci,netdev=${nid}"
                    -netdev  "user,id=${nid},hostfwd=tcp::${host_port}-:${guest_port}"
                )
                print_status "INFO" "Port forward: localhost:${host_port} → VM:${guest_port}"
                ((netdev_idx++))
            else
                print_status "WARN" "Skipping invalid port forward: '$forward'"
            fi
        done
    fi

    # ── Display ──────────────────────────────────────────────────────────────
    if [[ "${VNC_MODE:-false}" == true && -n "${VNC_PORT:-}" ]]; then
        local vnc_display=$(( VNC_PORT - 5900 ))
        qemu_cmd+=(-vnc ":${vnc_display}")
        # USB tablet for correct mouse tracking in VNC
        qemu_cmd+=(-device usb-ehci -device usb-tablet)
        print_status "INFO" "VNC: connect to localhost:${VNC_PORT}  (display :${vnc_display})"
        # Record VNC port for info display
        echo "$VNC_PORT" > "$(vm_vnc_file "$vm_name")"
    elif [[ "${GUI_MODE:-false}" == true ]]; then
        # USB tablet fixes mouse offset in GTK window
        qemu_cmd+=(-device usb-ehci -device usb-tablet -vga virtio)
        if [[ -n "${DISPLAY:-}" ]]; then
            qemu_cmd+=(-display gtk)
        else
            # Fall back to VNC on :0 if no X11 display available
            print_status "WARN" "No DISPLAY set — falling back to VNC on port 5900"
            qemu_cmd+=(-vnc :0)
        fi
        print_status "INFO" "Starting in GUI mode"
    else
        qemu_cmd+=(-nographic -serial mon:stdio)
        print_status "INFO" "Starting in console mode (Ctrl+A X to exit)"
    fi

    # ── Run mode (detach if VNC/GTK, attach for console) ────────────────────
    if [[ "${VNC_MODE:-false}" == true || "${GUI_MODE:-false}" == true ]]; then
        # Run detached in background and store PID
        print_status "INFO" "Starting VM in background..."
        "${qemu_cmd[@]}" \
            >> "$log_out" 2>&1 &
        local qemu_pid=$!
        echo "$qemu_pid" > "$pid_file"
        sleep 1
        if kill -0 "$qemu_pid" 2>/dev/null; then
            print_status "SUCCESS" "VM '$vm_name' started (PID $qemu_pid)"
            if [[ "${VNC_MODE:-false}" == true ]]; then
                print_status "INFO" "Connect via VNC: localhost:${VNC_PORT}"
            fi
            print_status "INFO" "Logs: $log_out"
        else
            print_status "ERROR" "VM failed to start. Check logs: $log_out"
            rm -f "$pid_file"
            return 1
        fi
    else
        # Foreground console mode — blocks until QEMU exits
        "${qemu_cmd[@]}" || {
            print_status "ERROR" "QEMU exited with error. Check $log_out for details"
            rm -f "$pid_file" "$monitor_sock" 2>/dev/null || true
            return 1
        }
        rm -f "$pid_file" "$monitor_sock" 2>/dev/null || true
        print_status "INFO" "VM '$vm_name' has shut down"
    fi
}

# ─── Stop VM (ACPI first, then SIGTERM, then SIGKILL) ─────────────────────────
stop_vm() {
    local vm_name=$1
    load_vm_config "$vm_name" || return 1

    if ! is_vm_running "$vm_name"; then
        print_status "INFO" "VM '$vm_name' is not running"
        rm -f "$(vm_pid_file "$vm_name")" "$(vm_monitor_file "$vm_name")" 2>/dev/null || true
        return 0
    fi

    local monitor_sock
    monitor_sock="$(vm_monitor_file "$vm_name")"

    # 1) Try graceful ACPI shutdown via monitor socket
    if [[ -S "$monitor_sock" ]]; then
        print_status "INFO" "Sending ACPI power-off signal..."
        echo "system_powerdown" | socat - "UNIX-CONNECT:${monitor_sock}" >/dev/null 2>&1 || true
        local waited=0
        while [[ $waited -lt $QEMU_TIMEOUT ]]; do
            is_vm_running "$vm_name" || break
            sleep 1
            ((waited++))
        done
    fi

    # 2) SIGTERM
    if is_vm_running "$vm_name"; then
        print_status "WARN" "Graceful shutdown timed out — sending SIGTERM"
        local pid
        pid="$(get_vm_pid "$vm_name")"
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
        sleep 3
    fi

    # 3) SIGKILL
    if is_vm_running "$vm_name"; then
        print_status "WARN" "Still running — sending SIGKILL"
        local pid
        pid="$(get_vm_pid "$vm_name")"
        [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
        sleep 1
    fi

    rm -f "$(vm_pid_file "$vm_name")" "$(vm_monitor_file "$vm_name")" "$(vm_vnc_file "$vm_name")" 2>/dev/null || true

    if is_vm_running "$vm_name"; then
        print_status "ERROR" "Failed to stop VM '$vm_name'"
        return 1
    fi
    print_status "SUCCESS" "VM '$vm_name' stopped"
}

# ─── Delete VM ───────────────────────────────────────────────────────────────
delete_vm() {
    local vm_name=$1
    load_vm_config "$vm_name" || return 1

    separator
    print_status "WARN" "This will PERMANENTLY delete VM '$vm_name' and all its data!"
    print_status "WARN" "Files to delete:"
    echo "  • $IMG_FILE"
    echo "  • $SEED_FILE"
    echo "  • $(vm_conf_file "$vm_name")"
    separator
    read -rp "$(print_status "INPUT" "Type the VM name to confirm deletion: ")" confirm_name
    if [[ "$confirm_name" != "$vm_name" ]]; then
        print_status "INFO" "Name mismatch — deletion cancelled"
        return 0
    fi

    if is_vm_running "$vm_name"; then
        print_status "WARN" "VM is running — stopping it first..."
        stop_vm "$vm_name"
        sleep 1
    fi

    rm -f "$IMG_FILE" "$SEED_FILE" "$(vm_conf_file "$vm_name")" \
          "$(vm_pid_file "$vm_name")" "$(vm_monitor_file "$vm_name")" \
          "$(vm_log_file "$vm_name")" "$(vm_vnc_file "$vm_name")" \
          "${IMG_FILE}.lock" 2>/dev/null || true

    print_status "SUCCESS" "VM '$vm_name' deleted"
}

# ─── Show VM info ─────────────────────────────────────────────────────────────
show_vm_info() {
    local vm_name=$1
    load_vm_config "$vm_name" || return 1

    separator
    echo -e "\033[1;34m  VM: $vm_name\033[0m"
    separator
    printf "  %-18s %s\n" "OS:"         "$OS_TYPE ($CODENAME)"
    printf "  %-18s %s\n" "Hostname:"   "$HOSTNAME"
    printf "  %-18s %s\n" "Username:"   "$USERNAME"
    printf "  %-18s %s\n" "Password:"   "$PASSWORD"
    printf "  %-18s %s\n" "SSH Port:"   "$SSH_PORT"
    printf "  %-18s %s\n" "RAM:"        "${MEMORY} MB"
    printf "  %-18s %s\n" "CPUs:"       "$CPUS"
    printf "  %-18s %s\n" "Disk:"       "$DISK_SIZE"
    printf "  %-18s %s\n" "GUI Mode:"   "${GUI_MODE:-false}"
    printf "  %-18s %s\n" "VNC Mode:"   "${VNC_MODE:-false}"
    [[ -n "${VNC_PORT:-}" ]] && printf "  %-18s %s\n" "VNC Port:"   "$VNC_PORT"
    [[ -n "${PORT_FORWARDS:-}" ]] && printf "  %-18s %s\n" "Port Fwds:" "$PORT_FORWARDS"
    [[ -n "${SSH_KEY:-}" ]] && printf "  %-18s %s\n" "SSH Key:"   "${SSH_KEY:0:40}..."
    printf "  %-18s %s\n" "Created:"    "$CREATED"
    separator

    # Image status
    if [[ -f "$IMG_FILE" ]]; then
        local img_info
        img_info=$(qemu-img info "$IMG_FILE" 2>/dev/null | grep -E "disk size|virtual size" | sed 's/^/  /')
        echo -e "\033[1m  Disk image:\033[0m"
        echo "$img_info"
    else
        printf "  %-18s %s\n" "Image:" "NOT FOUND ($IMG_FILE)"
    fi

    separator
    # BUG FIX: original code called check_image_lock (which is interactive) here.
    # Now use the non-interactive is_image_locked instead.
    if is_image_locked "$IMG_FILE" 2>/dev/null; then
        echo -e "  🔒 Image Status: \033[1;33mLocked (in use)\033[0m"
    else
        echo -e "  🔓 Image Status: \033[1;32mUnlocked\033[0m"
    fi

    if is_vm_running "$vm_name"; then
        local pid
        pid="$(get_vm_pid "$vm_name")"
        echo -e "  🚀 Status:       \033[1;32mRunning\033[0m (PID $pid)"
        echo
        echo -e "  \033[1mQuick connect:\033[0m"
        echo "    ssh -p $SSH_PORT $USERNAME@localhost"
        [[ -n "${VNC_PORT:-}" ]] && echo "    VNC: localhost:${VNC_PORT}"
    else
        echo -e "  💤 Status:       \033[1;33mStopped\033[0m"
    fi
    separator
    echo

    # Show snapshots if any
    if [[ -f "$IMG_FILE" ]]; then
        local snapshots
        snapshots=$(qemu-img snapshot -l "$IMG_FILE" 2>/dev/null | tail -n +3)
        if [[ -n "$snapshots" ]]; then
            echo -e "  \033[1mSnapshots:\033[0m"
            echo "$snapshots" | sed 's/^/    /'
            echo
        fi
    fi

    read -rp "$(print_status "INPUT" "Press Enter to continue...")"
}

# ─── Performance metrics ─────────────────────────────────────────────────────
show_vm_performance() {
    local vm_name=$1
    load_vm_config "$vm_name" || return 1

    separator
    if is_vm_running "$vm_name"; then
        local pid
        pid="$(get_vm_pid "$vm_name")"
        echo -e "\033[1m  Performance — $vm_name (PID $pid)\033[0m"
        separator

        echo -e "\033[1m  QEMU process:\033[0m"
        ps -p "$pid" -o pid,%cpu,%mem,rss,vsz --no-headers 2>/dev/null \
            | awk '{printf "    PID: %-8s CPU: %-6s MEM: %-6s RSS: %-10s VSZ: %s\n", $1, $2"%", $3"%", $4" KB", $5" KB"}'

        echo
        echo -e "\033[1m  Host memory:\033[0m"
        free -h | sed 's/^/    /'

        echo
        echo -e "\033[1m  Disk image:\033[0m"
        du -h "$IMG_FILE" 2>/dev/null | sed 's/^/    /'
        qemu-img info "$IMG_FILE" 2>/dev/null | grep -E "disk size|virtual size" | sed 's/^/    /'
    else
        echo -e "  💤 VM '$vm_name' is not running"
        echo
        printf "  %-12s %s\n" "Config RAM:" "${MEMORY} MB"
        printf "  %-12s %s\n" "Config CPU:" "$CPUS"
        printf "  %-12s %s\n" "Disk size:"  "$DISK_SIZE"
        [[ -f "$IMG_FILE" ]] && du -h "$IMG_FILE" | awk '{printf "  %-12s %s\n", "Actual disk:", $1}'
    fi
    separator
    read -rp "$(print_status "INPUT" "Press Enter to continue...")"
}

# ─── Edit VM config ───────────────────────────────────────────────────────────
edit_vm_config() {
    local vm_name=$1
    load_vm_config "$vm_name" || return 1

    local changed_credentials=false

    while true; do
        separator
        echo -e "\033[1m  Editing: $vm_name\033[0m"
        separator
        echo "   1) Hostname         (current: $HOSTNAME)"
        echo "   2) Username         (current: $USERNAME)"
        echo "   3) Password         (current: ****)"
        echo "   4) SSH Port         (current: $SSH_PORT)"
        echo "   5) Display Mode     (current: GUI=${GUI_MODE:-false}, VNC=${VNC_MODE:-false})"
        echo "   6) Port Forwards    (current: ${PORT_FORWARDS:-none})"
        echo "   7) RAM              (current: ${MEMORY} MB)"
        echo "   8) CPUs             (current: $CPUS)"
        echo "   9) Disk Size        (resize disk — VM must be stopped)"
        echo "  10) SSH Public Key   (current: ${SSH_KEY:+set}${SSH_KEY:-not set})"
        echo "   0) Back"
        separator

        read -rp "$(print_status "INPUT" "Choice: ")" ec

        case $ec in
            1)
                while true; do
                    read -rp "$(print_status "INPUT" "New hostname [$HOSTNAME]: ")" v
                    v="${v:-$HOSTNAME}"
                    validate_input "name" "$v" && HOSTNAME="$v" && changed_credentials=true && break
                done ;;
            2)
                while true; do
                    read -rp "$(print_status "INPUT" "New username [$USERNAME]: ")" v
                    v="${v:-$USERNAME}"
                    validate_input "username" "$v" && USERNAME="$v" && changed_credentials=true && break
                done ;;
            3)
                while true; do
                    read -rsp "$(print_status "INPUT" "New password (Enter to keep): ")" v
                    echo
                    [[ -z "$v" ]] && break
                    [[ -n "$v" ]] && PASSWORD="$v" && changed_credentials=true && break
                done ;;
            4)
                while true; do
                    read -rp "$(print_status "INPUT" "New SSH port [$SSH_PORT]: ")" v
                    v="${v:-$SSH_PORT}"
                    if ! validate_input "port" "$v"; then continue; fi
                    if [[ "$v" != "$SSH_PORT" ]] && is_port_in_use "$v" "$vm_name"; then
                        print_status "ERROR" "Port $v is already in use"
                    else
                        SSH_PORT="$v"; break
                    fi
                done ;;
            5)
                GUI_MODE=false; VNC_MODE=false; VNC_PORT=""
                echo "  1) Headless  2) VNC  3) GTK"
                read -rp "$(print_status "INPUT" "Display [1]: ")" dm
                dm="${dm:-1}"
                case $dm in
                    2)
                        VNC_MODE=true
                        while true; do
                            read -rp "$(print_status "INPUT" "VNC port [5900]: ")" vp; vp="${vp:-5900}"
                            if ! validate_input "port" "$vp"; then continue; fi
                            if is_port_in_use "$vp" "$vm_name"; then
                                print_status "ERROR" "Port $vp in use"
                            else
                                VNC_PORT="$vp"; break
                            fi
                        done ;;
                    3) GUI_MODE=true ;;
                esac ;;
            6)
                read -rp "$(print_status "INPUT" "Port forwards [${PORT_FORWARDS:-none}]: ")" v
                PORT_FORWARDS="${v:-$PORT_FORWARDS}" ;;
            7)
                while true; do
                    read -rp "$(print_status "INPUT" "New RAM in MB [$MEMORY]: ")" v
                    v="${v:-$MEMORY}"
                    validate_input "number" "$v" && MEMORY="$v" && break
                done ;;
            8)
                while true; do
                    read -rp "$(print_status "INPUT" "New CPU count [$CPUS]: ")" v
                    v="${v:-$CPUS}"
                    validate_input "number" "$v" && CPUS="$v" && break
                done ;;
            9)
                # BUG FIX: original only updated the variable without calling qemu-img resize.
                # Now we call resize_vm_disk directly.
                resize_vm_disk "$vm_name"
                # Reload config after resize (it saves internally)
                load_vm_config "$vm_name" ;;
            10)
                read -rp "$(print_status "INPUT" "SSH public key (blank to clear): ")" v
                SSH_KEY="$v"
                changed_credentials=true ;;
            0) break ;;
            *) print_status "ERROR" "Invalid selection" ;;
        esac

        # Regenerate seed if credentials/hostname changed (not for disk/cpu/ram)
        if $changed_credentials && [[ "$ec" =~ ^[123]$|^10$ ]]; then
            print_status "INFO" "Regenerating cloud-init seed with updated credentials..."
            if is_vm_running "$vm_name"; then
                print_status "WARN" "Changes take effect after next VM restart"
            fi
            create_seed_image || print_status "WARN" "Seed regeneration failed; start VM to retry"
            changed_credentials=false
        fi

        save_vm_config
        print_status "SUCCESS" "Saved"
    done
}

# ─── Resize VM disk ───────────────────────────────────────────────────────────
resize_vm_disk() {
    local vm_name=$1
    load_vm_config "$vm_name" || return 1

    if is_vm_running "$vm_name"; then
        print_status "ERROR" "Stop the VM before resizing its disk"
        return 1
    fi

    print_status "INFO" "Current disk size: $DISK_SIZE"
    local img_info
    img_info=$(qemu-img info "$IMG_FILE" 2>/dev/null | grep -E "disk size|virtual size" | sed 's/^/  /')
    echo "$img_info"

    while true; do
        read -rp "$(print_status "INPUT" "New disk size (e.g. 50G): ")" new_size
        if ! validate_input "size" "$new_size"; then continue; fi
        if [[ "$new_size" == "$DISK_SIZE" ]]; then
            print_status "INFO" "Same size — nothing to do"
            return 0
        fi

        # Convert both sizes to MB for comparison
        size_to_mb() {
            local s=$1; local n="${s%[GgMm]}"; local u="${s: -1}"
            [[ "$u" =~ [Gg] ]] && echo $((n * 1024)) || echo "$n"
        }
        local cur_mb new_mb
        cur_mb=$(size_to_mb "$DISK_SIZE")
        new_mb=$(size_to_mb "$new_size")

        if [[ $new_mb -lt $cur_mb ]]; then
            print_status "WARN" "Shrinking may cause data loss and is NOT recommended!"
            read -rp "$(print_status "INPUT" "Proceed anyway? (y/N): ")" confirm
            [[ "$confirm" =~ ^[Yy]$ ]] || { print_status "INFO" "Cancelled"; return 0; }
        fi

        print_status "INFO" "Resizing disk to $new_size..."
        if qemu-img resize "$IMG_FILE" "$new_size"; then
            DISK_SIZE="$new_size"
            save_vm_config
            print_status "SUCCESS" "Disk resized to $new_size"
            print_status "INFO" "You may need to run 'growpart' and 'resize2fs' inside the VM to use the new space"
        else
            print_status "ERROR" "qemu-img resize failed"
            return 1
        fi
        break
    done
}

# ─── Clone VM ─────────────────────────────────────────────────────────────────
clone_vm() {
    local src_name=$1
    load_vm_config "$src_name" || return 1

    if is_vm_running "$src_name"; then
        print_status "ERROR" "Stop '$src_name' before cloning"
        return 1
    fi

    local clone_name
    while true; do
        read -rp "$(print_status "INPUT" "Name for the cloned VM: ")" clone_name
        if ! validate_input "name" "$clone_name"; then continue; fi
        if [[ -f "$(vm_conf_file "$clone_name")" ]]; then
            print_status "ERROR" "A VM named '$clone_name' already exists"
        else
            break
        fi
    done

    local src_ssh=$SSH_PORT
    local new_ssh
    while true; do
        read -rp "$(print_status "INPUT" "SSH port for clone (current VM uses $src_ssh): ")" new_ssh
        if ! validate_input "port" "$new_ssh"; then continue; fi
        if is_port_in_use "$new_ssh"; then
            print_status "ERROR" "Port $new_ssh is in use"
        else
            break
        fi
    done

    local src_img="$IMG_FILE"
    local src_seed="$SEED_FILE"

    # Update config for clone
    VM_NAME="$clone_name"
    IMG_FILE="$(vm_img_file "$clone_name")"
    SEED_FILE="$(vm_seed_file "$clone_name")"
    SSH_PORT="$new_ssh"
    CREATED="$(date '+%Y-%m-%d %H:%M:%S') (cloned from $src_name)"

    print_status "INFO" "Cloning disk image (this may take a while)..."
    if qemu-img create -f qcow2 -F qcow2 -b "$src_img" "$IMG_FILE"; then
        print_status "SUCCESS" "Disk cloned (copy-on-write from source)"
    else
        print_status "INFO" "Backing-file clone failed — doing full copy..."
        if ! cp --sparse=always "$src_img" "$IMG_FILE"; then
            print_status "ERROR" "Failed to clone disk"
            return 1
        fi
    fi

    cp "$src_seed" "$SEED_FILE" 2>/dev/null || create_seed_image
    save_vm_config
    print_status "SUCCESS" "VM '$clone_name' cloned from '$src_name'"
}

# ─── Snapshot management ─────────────────────────────────────────────────────
manage_snapshots() {
    local vm_name=$1
    load_vm_config "$vm_name" || return 1

    while true; do
        separator
        echo -e "\033[1m  Snapshots — $vm_name\033[0m"
        separator

        # List current snapshots
        local snap_list
        snap_list=$(qemu-img snapshot -l "$IMG_FILE" 2>/dev/null | tail -n +3)
        if [[ -n "$snap_list" ]]; then
            echo "  Current snapshots:"
            echo "$snap_list" | nl -ba -nrz -w3 | sed 's/^/  /'
        else
            echo "  No snapshots found"
        fi
        separator

        echo "  1) Create snapshot"
        echo "  2) Restore snapshot"
        echo "  3) Delete snapshot"
        echo "  0) Back"
        separator

        read -rp "$(print_status "INPUT" "Choice: ")" sc

        case $sc in
            1)
                if is_vm_running "$vm_name"; then
                    print_status "WARN" "Creating snapshot of running VM — state may be inconsistent"
                    print_status "WARN" "For consistent snapshots, stop the VM first"
                    read -rp "$(print_status "INPUT" "Continue? (y/N): ")" ok
                    [[ "$ok" =~ ^[Yy]$ ]] || continue
                fi
                local snap_name
                read -rp "$(print_status "INPUT" "Snapshot name: ")" snap_name
                if [[ -z "$snap_name" ]]; then
                    print_status "ERROR" "Snapshot name cannot be empty"
                    continue
                fi
                if qemu-img snapshot -c "$snap_name" "$IMG_FILE"; then
                    print_status "SUCCESS" "Snapshot '$snap_name' created"
                else
                    print_status "ERROR" "Failed to create snapshot"
                fi ;;
            2)
                if is_vm_running "$vm_name"; then
                    print_status "ERROR" "Stop the VM before restoring a snapshot"
                    continue
                fi
                read -rp "$(print_status "INPUT" "Snapshot name to restore: ")" snap_name
                if [[ -z "$snap_name" ]]; then continue; fi
                print_status "WARN" "All changes since snapshot '$snap_name' will be LOST!"
                read -rp "$(print_status "INPUT" "Confirm? (y/N): ")" ok
                if [[ "$ok" =~ ^[Yy]$ ]]; then
                    if qemu-img snapshot -a "$snap_name" "$IMG_FILE"; then
                        print_status "SUCCESS" "Restored to snapshot '$snap_name'"
                    else
                        print_status "ERROR" "Restore failed"
                    fi
                fi ;;
            3)
                read -rp "$(print_status "INPUT" "Snapshot name to delete: ")" snap_name
                if [[ -z "$snap_name" ]]; then continue; fi
                if qemu-img snapshot -d "$snap_name" "$IMG_FILE"; then
                    print_status "SUCCESS" "Snapshot '$snap_name' deleted"
                else
                    print_status "ERROR" "Delete failed"
                fi ;;
            0) break ;;
            *) print_status "ERROR" "Invalid selection" ;;
        esac
        echo
        read -rp "$(print_status "INPUT" "Press Enter to continue...")"
    done
}

# ─── Fix VM issues ────────────────────────────────────────────────────────────
fix_vm_issues() {
    local vm_name=$1
    load_vm_config "$vm_name" || return 1

    separator
    echo "  Fix options for: $vm_name"
    separator
    echo "  1) Remove stale lock files"
    echo "  2) Recreate seed image (cloud-init)"
    echo "  3) Re-save configuration file"
    echo "  4) Kill all QEMU processes for this VM"
    echo "  5) Check and repair disk image"
    echo "  0) Back"
    separator

    read -rp "$(print_status "INPUT" "Choice: ")" fc

    case $fc in
        1)
            rm -f "${IMG_FILE}.lock" "${IMG_FILE}"*.lock "$(vm_pid_file "$vm_name")" 2>/dev/null || true
            print_status "SUCCESS" "Lock and PID files removed" ;;
        2)
            print_status "INFO" "Recreating seed image..."
            rm -f "$SEED_FILE"
            create_seed_image ;;
        3)
            save_vm_config ;;
        4)
            print_status "INFO" "Killing QEMU processes for $vm_name..."
            pkill -f "qemu-system.*${vm_name}" 2>/dev/null || true
            sleep 1
            pkill -9 -f "qemu-system.*${vm_name}" 2>/dev/null || true
            rm -f "$(vm_pid_file "$vm_name")" "$(vm_monitor_file "$vm_name")" 2>/dev/null || true
            is_vm_running "$vm_name" \
                && print_status "ERROR" "Could not kill all processes" \
                || print_status "SUCCESS" "All processes terminated" ;;
        5)
            if is_vm_running "$vm_name"; then
                print_status "ERROR" "Stop the VM before checking the disk"
            else
                print_status "INFO" "Checking disk image..."
                if qemu-img check "$IMG_FILE"; then
                    print_status "SUCCESS" "Disk image is OK"
                else
                    print_status "WARN" "Issues found — attempting repair..."
                    qemu-img check -r all "$IMG_FILE" \
                        && print_status "SUCCESS" "Repair completed" \
                        || print_status "ERROR" "Repair failed — consider restoring from snapshot or backup"
                fi
            fi ;;
        0) return 0 ;;
        *) print_status "ERROR" "Invalid selection" ;;
    esac
    echo
    read -rp "$(print_status "INPUT" "Press Enter to continue...")"
}

# ─── VM selector helper ───────────────────────────────────────────────────────
select_vm() {
    local prompt=$1
    local vms=("$@")
    # Remove first element (the prompt)
    unset 'vms[0]'
    vms=("${vms[@]}")

    local vm_count=${#vms[@]}
    local num
    read -rp "$(print_status "INPUT" "$prompt (1-${vm_count}): ")" num
    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "$vm_count" ]; then
        echo "${vms[$((num-1))]}"
        return 0
    fi
    print_status "ERROR" "Invalid selection"
    return 1
}

# ─── Main menu ────────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        display_header

        # Collect VM list once per loop
        mapfile -t vms < <(get_vm_list)
        local vm_count=${#vms[@]}

        # Display existing VMs
        if [ $vm_count -gt 0 ]; then
            echo -e "  \033[1mExisting VMs ($vm_count):\033[0m"
            echo
            for i in "${!vms[@]}"; do
                local status_icon="💤"
                local status_color="\033[0;90m"
                if is_vm_running "${vms[$i]}"; then
                    status_icon="🚀"
                    status_color="\033[0;32m"
                fi
                printf "  ${status_color}%3d) %s %s\033[0m\n" $((i+1)) "${vms[$i]}" "$status_icon"
            done
            echo
        fi

        separator
        echo -e "  \033[1mMain Menu:\033[0m"
        echo "   1) Create new VM"
        if [ $vm_count -gt 0 ]; then
            echo "   2) Start VM"
            echo "   3) Stop VM"
            echo "   4) VM info"
            echo "   5) Edit VM"
            echo "   6) Clone VM"
            echo "   7) Resize disk"
            echo "   8) Snapshots"
            echo "   9) Performance"
            echo "  10) Fix issues"
            echo "  11) Delete VM"
        fi
        echo "   0) Exit"
        separator

        read -rp "$(print_status "INPUT" "Choice: ")" choice

        case $choice in
            1)
                create_new_vm
                ;;
            2)
                [ $vm_count -eq 0 ] && continue
                read -rp "$(print_status "INPUT" "VM number to start: ")" n
                if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$vm_count" ]; then
                    start_vm "${vms[$((n-1))]}"
                else
                    print_status "ERROR" "Invalid selection"
                fi
                ;;
            3)
                [ $vm_count -eq 0 ] && continue
                read -rp "$(print_status "INPUT" "VM number to stop: ")" n
                if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$vm_count" ]; then
                    stop_vm "${vms[$((n-1))]}"
                else
                    print_status "ERROR" "Invalid selection"
                fi
                ;;
            4)
                [ $vm_count -eq 0 ] && continue
                read -rp "$(print_status "INPUT" "VM number for info: ")" n
                if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$vm_count" ]; then
                    show_vm_info "${vms[$((n-1))]}"
                else
                    print_status "ERROR" "Invalid selection"
                fi
                ;;
            5)
                [ $vm_count -eq 0 ] && continue
                read -rp "$(print_status "INPUT" "VM number to edit: ")" n
                if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$vm_count" ]; then
                    edit_vm_config "${vms[$((n-1))]}"
                else
                    print_status "ERROR" "Invalid selection"
                fi
                ;;
            6)
                [ $vm_count -eq 0 ] && continue
                read -rp "$(print_status "INPUT" "VM number to clone: ")" n
                if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$vm_count" ]; then
                    clone_vm "${vms[$((n-1))]}"
                else
                    print_status "ERROR" "Invalid selection"
                fi
                ;;
            7)
                [ $vm_count -eq 0 ] && continue
                read -rp "$(print_status "INPUT" "VM number to resize: ")" n
                if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$vm_count" ]; then
                    resize_vm_disk "${vms[$((n-1))]}"
                else
                    print_status "ERROR" "Invalid selection"
                fi
                ;;
            8)
                [ $vm_count -eq 0 ] && continue
                read -rp "$(print_status "INPUT" "VM number for snapshots: ")" n
                if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$vm_count" ]; then
                    manage_snapshots "${vms[$((n-1))]}"
                else
                    print_status "ERROR" "Invalid selection"
                fi
                ;;
            9)
                [ $vm_count -eq 0 ] && continue
                read -rp "$(print_status "INPUT" "VM number for performance: ")" n
                if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$vm_count" ]; then
                    show_vm_performance "${vms[$((n-1))]}"
                else
                    print_status "ERROR" "Invalid selection"
                fi
                ;;
            10)
                [ $vm_count -eq 0 ] && continue
                read -rp "$(print_status "INPUT" "VM number to fix: ")" n
                if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$vm_count" ]; then
                    fix_vm_issues "${vms[$((n-1))]}"
                else
                    print_status "ERROR" "Invalid selection"
                fi
                ;;
            11)
                [ $vm_count -eq 0 ] && continue
                read -rp "$(print_status "INPUT" "VM number to delete: ")" n
                if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$vm_count" ]; then
                    delete_vm "${vms[$((n-1))]}"
                else
                    print_status "ERROR" "Invalid selection"
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

        if [[ "$choice" != "2" || "${VNC_MODE:-false}" == true || "${GUI_MODE:-false}" == true ]]; then
            # Don't pause after a blocking console start (choice 2, headless)
            echo
            read -rp "$(print_status "INPUT" "Press Enter to continue...")"
        fi
    done
}

# ─── Entry point ──────────────────────────────────────────────────────────────
check_dependencies
mkdir -p "$VM_DIR"
log "=== vm-manager started (v${SCRIPT_VERSION}) ==="
main_menu
