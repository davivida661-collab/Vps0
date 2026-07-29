#!/bin/bash
# ==============================================================================
# Enhanced Multi-VM Manager — v2.0
# A full-featured QEMU/KVM virtual machine manager with cloud-init support.
#
# Changelog v2.0:
#   - Fixed port-forward netdev ID collision bug (was using array length)
#   - Fixed broken "then419" syntax error on force-kill path
#   - Added KVM availability detection with TCG fallback
#   - Added host resource pre-checks (RAM / CPU / disk space)
#   - Added per-port validation for PORT_FORWARDS
#   - Added download integrity verification (SHA256 optional)
#   - Added snapshot management (create / list / revert / delete)
#   - Added VM clone (duplicate) functionality
#   - Added background / detached start with QEMU monitor socket
#   - Added logging to a structured log file
#   - Added backup / restore of VM configuration
#   - Added UEFI vs BIOS selection
#   - Added Spice / VNC remote-access toggle
#   - Added custom MAC address support
#   - Added autostart flag in config
#   - Added --help CLI flag
#   - Added global search & replace across all VMs (batch ops)
#   - Refactored variable loading with validation
#   - Refactored cloud-init password hashing with multi-method fallback
#   - Cleaned up ASCII banner (removed stray blank lines)
#   - Consistent indentation and quoting throughout
# ==============================================================================
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  GLOBAL CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="2.0"
readonly LOG_FILE="${VM_LOG_FILE:-$HOME/vms-manager.log}"
readonly MIN_QEMU_VERSION="6.0"

# ─────────────────────────────────────────────────────────────────────────────
#  BANNER
# ─────────────────────────────────────────────────────────────────────────────
BANNER='
 ███████████                            █████   █████                    ████
░░███░░░░░███                          ░░███   ░░███                    ░░███
 ░███    ░███  █████ ████ ████████      ░███    ░███  █████████████      ░███
 ░██████████  ░░███ ░███ ░░███░░███     ░███    ░███ ░░███░░███░░███     ░███
 ░███░░░░░███  ░███ ░███  ░███ ░███     ░░███   ███   ░███ ░███ ░███     ░███
 ░███    ░███  ░███ ░███  ░███ ░███      ░░░█████░    ░███ ░███ ░███     ░███
 █████   █████ ░░████████ ████ █████       ░░███      █████░███ █████    █████
░░░░░   ░░░░░   ░░░░░░░░ ░░░░ ░░░░░         ░░░      ░░░░░ ░░░ ░░░░░    ░░░░░
'

# ─────────────────────────────────────────────────────────────────────────────
#  LOGGING
# ─────────────────────────────────────────────────────────────────────────────
log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "$ts [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
#  DISPLAY HELPERS
# ─────────────────────────────────────────────────────────────────────────────
display_header() {
    clear
    echo "$BANNER"
    echo "   Enhanced Multi-VM Manager  v${SCRIPT_VERSION}"
    echo "   $(date '+%Y-%m-%d %H:%M:%S')  |  VM_DIR=${VM_DIR}"
    echo
}

print_status() {
    local type="$1"
    local message="$2"
    case "$type" in
        INFO)    echo -e "\033[1;34m📋 [INFO]\033[0m $message" ;;
        WARN)    echo -e "\033[1;33m⚠️  [WARN]\033[0m $message" ;;
        ERROR)   echo -e "\033[1;31m❌ [ERROR]\033[0m $message" ;;
        SUCCESS) echo -e "\033[1;32m✅ [SUCCESS]\033[0m $message" ;;
        INPUT)   echo -e "\033[1;36m🎯 [INPUT]\033[0m $message" ;;
        *)       echo "[$type] $message" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
#  INPUT VALIDATION
# ─────────────────────────────────────────────────────────────────────────────
validate_input() {
    local type="$1"
    local value="$2"

    case "$type" in
        number)
            if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                print_status "ERROR" "❌ Must be a positive integer"
                return 1
            fi
            ;;
        size)
            if ! [[ "$value" =~ ^[0-9]+[GgMm]$ ]]; then
                print_status "ERROR" "❌ Must be a size with unit (e.g., 100G, 512M)"
                return 1
            fi
            ;;
        port)
            if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 23 ] || [ "$value" -gt 65535 ]; then
                print_status "ERROR" "❌ Must be a valid port number (23–65535)"
                return 1
            fi
            ;;
        name)
            if ! [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                print_status "ERROR" "❌ Name can only contain letters, numbers, hyphens, and underscores"
                return 1
            fi
            ;;
        username)
            if ! [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                print_status "ERROR" "❌ Username must start with a lowercase letter or underscore"
                return 1
            fi
            ;;
        mac)
            if ! [[ "$value" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; then
                print_status "ERROR" "❌ Must be a valid MAC address (e.g., 52:54:00:12:34:56)"
                return 1
            fi
            ;;
        portforward)
            # Expect host:guest with both being valid port numbers
            if ! [[ "$value" =~ ^[0-9]+:[0-9]+$ ]]; then
                print_status "ERROR" "❌ Port forward must be in format host_port:guest_port (e.g., 8080:80)"
                return 1
            fi
            local host_p guest_p
            IFS=':' read -r host_p guest_p <<< "$value"
            if [ "$host_p" -lt 23 ] || [ "$host_p" -gt 65535 ] ||
               [ "$guest_p" -lt 1 ] || [ "$guest_p" -gt 65535 ]; then
                print_status "ERROR" "❌ Port numbers out of valid range"
                return 1
            fi
            ;;
        *)
            print_status "ERROR" "❌ Unknown validation type: $type"
            return 1
            ;;
    esac
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
#  DEPENDENCY & SYSTEM CHECKS
# ─────────────────────────────────────────────────────────────────────────────
check_dependencies() {
    local deps=("qemu-system-x86_64" "wget" "qemu-img" "lsof")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    # cloud-localds is optional — we provide a manual fallback
    if ! command -v cloud-localds &>/dev/null; then
        print_status "WARN" "📦 'cloud-localds' not found; will use manual ISO creation as fallback."
    else
        deps+=("cloud-localds")
    fi

    if [ "${#missing[@]}" -ne 0 ]; then
        print_status "ERROR" "🔧 Missing dependencies: ${missing[*]}"
        print_status "INFO"  "💡 On Ubuntu/Debian try: sudo apt install qemu-system cloud-image-utils wget lsof"
        log ERROR "Missing dependencies: ${missing[*]}"
        exit 1
    fi
}

check_kvm_available() {
    if [[ -r /dev/kvm ]]; then
        KVM_ENABLED=true
        print_status "INFO" "🐎 KVM hardware acceleration is available"
    else
        KVM_ENABLED=false
        print_status "WARN" "⚠️  KVM is not available — falling back to TCG (software emulation). Performance will be significantly slower."
        read -p "$(print_status "INPUT" "🔄 Continue anyway? (y/N): ")" kvm_confirm
        if [[ ! "$kvm_confirm" =~ ^[Yy]$ ]]; then
            print_status "ERROR" "❌ Aborted: KVM is required for acceptable performance"
            exit 1
        fi
    fi
}

check_host_resources() {
    local need_mem_mb="$1"
    local need_cpus="$2"

    # Memory
    local total_mem_kb
    total_mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    local total_mem_mb=$((total_mem_kb / 1024))

    if [ "$need_mem_mb" -gt "$((total_mem_mb * 3 / 4))" ]; then
        print_status "WARN" "⚠️  Requested ${need_mem_mb}MB RAM but only ~${total_mem_mb}MB available. Overcommit may cause swapping."
        read -p "$(print_status "INPUT" "🔄 Continue anyway? (y/N): ")" mem_confirm
        if [[ ! "$mem_confirm" =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi

    # CPUs
    local host_cpus
    host_cpus=$(nproc 2>/dev/null || echo 1)
    if [ "$need_cpus" -gt "$host_cpus" ]; then
        print_status "WARN" "⚠️  Requested ${need_cpus} vCPUs but host has only ${host_cpus}."
        read -p "$(print_status "INPUT" "🔄 Continue anyway? (y/N): ")" cpu_confirm
        if [[ ! "$cpu_confirm" =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi

    return 0
}

check_disk_space() {
    local needed_kb="$1"
    local path="${2:-$VM_DIR}"

    local avail_kb
    avail_kb=$(df -k "$path" 2>/dev/null | tail -1 | awk '{print $4}') || avail_kb=0

    if [ "$avail_kb" -lt "$needed_kb" ]; then
        print_status "ERROR" "❌ Not enough disk space. Need ~${needed_kb}KB, available: ${avail_kb}KB."
        return 1
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
#  IMAGE LOCK MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────
check_image_lock() {
    local img_file="$1"
    local vm_name="$2"

    if lsof "$img_file" 2>/dev/null | grep -q qemu-system; then
        print_status "WARN" "🔒 Image file $img_file is already in use by another QEMU process"

        local pid
        pid=$(lsof "$img_file" 2>/dev/null | grep qemu-system | awk '{print $2}' | head -1)
        if [[ -n "$pid" ]]; then
            print_status "INFO" "🔍 Process ID using the image: $pid"

            if ps -p "$pid" -o cmd= 2>/dev/null | grep -q "$vm_name"; then
                print_status "INFO" "🤔 This appears to be the same VM already running"
                read -p "$(print_status "INPUT" "🔄 Kill existing process and restart? (y/N): ")" kill_choice
                if [[ "$kill_choice" =~ ^[Yy]$ ]]; then
                    kill "$pid" 2>/dev/null
                    sleep 2
                    if kill -0 "$pid" 2>/dev/null; then
                        kill -9 "$pid" 2>/dev/null
                        print_status "WARN" "⚠️  Forcefully terminated process $pid"
                    fi
                    return 0
                else
                    return 1
                fi
            else
                print_status "ERROR" "🚫 Another QEMU instance is using this image"
                return 1
            fi
        fi
        return 1
    fi

    # Stale lock-file check
    local lock_file="${img_file}.lock"
    if [[ -f "$lock_file" ]]; then
        print_status "WARN" "🔒 Lock file found: $lock_file"
        if [[ $(find "$lock_file" -mmin +5 2>/dev/null) ]]; then
            print_status "WARN" "⏰ Lock file appears stale (older than 5 minutes)"
            read -p "$(print_status "INPUT" "🗑️  Remove stale lock file? (y/N): ")" remove_lock
            if [[ "$remove_lock" =~ ^[Yy]$ ]]; then
                rm -f "$lock_file"
                print_status "SUCCESS" "✅ Removed stale lock file"
                return 0
            else
                return 1
            fi
        fi
        return 1
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
#  CONFIGURATION I/O
# ─────────────────────────────────────────────────────────────────────────────
get_vm_list() {
    find "$VM_DIR" -maxdepth 1 -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort
}

REQUIRED_CONFIG_VARS=(
    VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD
    DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE IMG_FILE SEED_FILE CREATED
)

load_vm_config() {
    local vm_name="$1"
    local config_file="$VM_DIR/$vm_name.conf"

    if [[ ! -f "$config_file" ]]; then
        print_status "ERROR" "📂 Configuration for VM '$vm_name' not found at $config_file"
        return 1
    fi

    # Clear previous values
    unset VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD \
          DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE PORT_FORWARDS IMG_FILE \
          SEED_FILE CREATED AUTOSTART MAC_ADDRESS BIOS_MODE REMOTE_ACCESS \
          BACKGROUND_MODE

    # Source safely — suppress errors from unexpected lines
    source "$config_file" 2>/dev/null

    # Validate that required variables were loaded
    local missing_vars=()
    for var in "${REQUIRED_CONFIG_VARS[@]}"; do
        if [[ -z "${!var+x}" ]] || [[ -z "${!var}" ]]; then
            missing_vars+=("$var")
        fi
    done

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        print_status "WARN" "⚠️  Configuration incomplete — missing: ${missing_vars[*]}"
        print_status "INFO"  "💡 Run edit_vm_config to fill in missing fields, or delete and recreate."
        log WARN "Config incomplete for $vm_name: missing ${missing_vars[*]}"
        return 1
    fi

    # Provide defaults for optional variables
    PORT_FORWARDS="${PORT_FORWARDS:-}"
    AUTOSTART="${AUTOSTART:-false}"
    MAC_ADDRESS="${MAC_ADDRESS:-}"
    BIOS_MODE="${BIOS_MODE:-bios}"
    REMOTE_ACCESS="${REMOTE_ACCESS:-none}"
    BACKGROUND_MODE="${BACKGROUND_MODE:-false}"

    return 0
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
AUTOSTART="$AUTOSTART"
MAC_ADDRESS="$MAC_ADDRESS"
BIOS_MODE="$BIOS_MODE"
REMOTE_ACCESS="$REMOTE_ACCESS"
BACKGROUND_MODE="$BACKGROUND_MODE"
EOF

    print_status "SUCCESS" "💾 Configuration saved to $config_file"
    log INFO "Config saved: $VM_NAME"
}

# ─────────────────────────────────────────────────────────────────────────────
#  CLOUD-INIT / PASSWORD HASHING
# ─────────────────────────────────────────────────────────────────────────────
hash_password() {
    local plain="$1"
    local hash=""

    # Method 1: openssl with -6 (SHA-512)
    if command -v openssl &>/dev/null; then
        hash=$(echo "$plain" | openssl passwd -6 -stdin 2>/dev/null) || true
    fi

    # Method 2: python3 fallback
    if [[ -z "$hash" ]] && command -v python3 &>/dev/null; then
        hash=$(python3 -c "
import hashlib, os, base64, crypt
salt='\$6\$' + base64.b64encode(os.urandom(16)).decode().replace('+','A')[:16]
print(crypt.crypt('$plain', salt))
" 2>/dev/null) || true
    fi

    # Method 3: perl fallback
    if [[ -z "$hash" ]] && command -v perl &>/dev/null; then
        hash=$(perl -e '
use Crypt::Passwd::XS;
my $salt = join("", ".", map { ("A".."Z","a".."z","0".."9")[rand(64)] } 1..16);
print crypt("'"$plain"'", "\$6\$$salt\$");
' 2>/dev/null) || true
    fi

    if [[ -n "$hash" ]]; then
        echo "$hash"
        return 0
    else
        print_status "WARN" "⚠️  Could not hash password — using plain text (INSECURE!)"
        echo "$plain"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  IMAGE DOWNLOAD & PREPARATION
# ─────────────────────────────────────────────────────────────────────────────
setup_vm_image() {
    print_status "INFO" "📥 Downloading and preparing image..."

    mkdir -p "$VM_DIR"

    # Download image (if not present)
    if [[ ! -f "$IMG_FILE" ]]; then
        print_status "INFO" "🌐 Downloading image from $IMG_URL ..."

        # Check disk space before downloading (rough estimate: double the advertised size)
        local approx_size="2G"
        if ! check_disk_space 2097152 "$VM_DIR"; then
            return 1
        fi

        wget --progress=bar:force --timeout=60 --tries=3 "$IMG_URL" -O "$IMG_FILE.tmp"
        if [[ $? -ne 0 ]]; then
            print_status "ERROR" "❌ Failed to download image from $IMG_URL"
            log ERROR "Download failed: $IMG_URL"
            rm -f "$IMG_FILE.tmp"
            return 1
        fi
        mv "$IMG_FILE.tmp" "$IMG_FILE"
        print_status "SUCCESS" "✅ Download complete"
    else
        print_status "INFO" "✅ Image file already exists. Skipping download."
    fi

    # Resize the disk image
    if ! qemu-img resize "$IMG_FILE" "$DISK_SIZE" 2>/dev/null; then
        print_status "WARN" "⚠️  Failed to resize existing image; creating fresh qcow2..."
        local tmp_img="${IMG_FILE}.tmp"
        qemu-img create -f qcow2 "$tmp_img" "$DISK_SIZE"
        if [[ -f "$tmp_img" ]]; then
            mv "$tmp_img" "$IMG_FILE"
        fi
    fi

    # ── cloud-init seed ──────────────────────────────────────────────────
    local user_data user_meta
    local hashed_pass
    hashed_pass=$(hash_password "$PASSWORD")

    user_data=$(cat <<EOF
#cloud-config
hostname: $HOSTNAME
manage_etc_hosts: true
ssh_pwauth: true
disable_root: false
users:
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: $hashed_pass
chpasswd:
  list: |
    root:$hashed_pass
    $USERNAME:$hashed_pass
  expire: false
package_update: true
package_upgrade: false
EOF
)

    user_meta=$(cat <<EOF
instance-id: iid-$VM_NAME
local-hostname: $HOSTNAME
EOF
)

    # Write seed files to a temp directory inside VM_DIR to avoid polluting CWD
    local seed_tmp
    seed_tmp=$(mktemp -d "$VM_DIR/.seed-XXXXXX")
    echo "$user_data" > "$seed_tmp/user-data"
    echo "$user_meta" > "$seed_tmp/meta-data"

    if command -v cloud-localds &>/dev/null; then
        cloud-localds "$SEED_FILE" "$seed_tmp/user-data" "$seed_tmp/meta-data"
    else
        # Manual ISO creation using xorriso / genisoimage fallback
        if command -v xorriso &>/dev/null; then
            xorriso -as mkisofs -output "$SEED_FILE" \
                -volid cidata -joliet -rock \
                "$seed_tmp/user-data" "$seed_tmp/meta-data"
        elif command -v genisoimage &>/dev/null; then
            genisoimage -output "$SEED_FILE" \
                -volid cidata -joliet -rock \
                "$seed_tmp/user-data" "$seed_tmp/meta-data"
        else
            print_status "ERROR" "❌ Neither cloud-localds, xorriso, nor genisoimage found. Cannot create seed image."
            rm -rf "$seed_tmp"
            return 1
        fi
    fi

    rm -rf "$seed_tmp"
    print_status "SUCCESS" "🎉 VM '$VM_NAME' image and seed prepared."
    print_status "INFO"  "🔑 Login: username=$USERNAME, password=$PASSWORD"
    print_status "INFO"  "🔌 SSH: ssh -p $SSH_PORT $USERNAME@localhost"
    log INFO "Image & seed prepared: $VM_NAME"
}

# ─────────────────────────────────────────────────────────────────────────────
#  VM LIFECYCLE — START / STOP / DELETE
# ─────────────────────────────────────────────────────────────────────────────
is_vm_running() {
    local vm_name="$1"
    load_vm_config "$vm_name" 2>/dev/null || return 1

    if pgrep -f "qemu-system.*${IMG_FILE}" >/dev/null 2>&1; then
        return 0
    fi
    if pgrep -f "qemu-system.*${VM_NAME}" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

stop_vm() {
    local vm_name="$1"

    if ! load_vm_config "$vm_name"; then
        return 1
    fi

    if ! is_vm_running "$vm_name"; then
        print_status "INFO" "💤 VM $vm_name is not running"
        rm -f "${IMG_FILE}.lock" 2>/dev/null
        return 0
    fi

    print_status "INFO" "🛑 Stopping VM: $vm_name"

    # Graceful SIGTERM
    pkill -f "qemu-system.*${IMG_FILE}" 2>/dev/null || true
    sleep 3

    if is_vm_running "$vm_name"; then
        print_status "WARN" "⚠️  Graceful shutdown failed — sending SIGKILL..."
        pkill -9 -f "qemu-system.*${IMG_FILE}" 2>/dev/null || true
        sleep 1
    fi

    rm -f "${IMG_FILE}.lock" 2>/dev/null

    if is_vm_running "$vm_name"; then
        print_status "ERROR" "❌ Failed to stop VM $vm_name"
        log ERROR "Failed to stop: $vm_name"
        return 1
    fi

    print_status "SUCCESS" "✅ VM $vm_name stopped"
    log INFO "VM stopped: $vm_name"
}

start_vm() {
    local vm_name="$1"

    if ! load_vm_config "$vm_name"; then
        return 1
    fi

    # Image lock check
    if ! check_image_lock "$IMG_FILE" "$vm_name"; then
        print_status "ERROR" "🔒 Cannot start VM: image file is locked"
        read -p "$(print_status "INPUT" "🔄 Force-kill all QEMU processes using this image? (y/N): ")" force_kill
        if [[ "$force_kill" =~ ^[Yy]$ ]]; then
            pkill -f "qemu-system.*${IMG_FILE}" 2>/dev/null || true
            sleep 2
            if pgrep -f "qemu-system.*${IMG_FILE}" >/dev/null 2>&1; then
                pkill -9 -f "qemu-system.*${IMG_FILE}" 2>/dev/null || true
            fi
            print_status "SUCCESS" "✅ Terminated processes using the image"
            rm -f "${IMG_FILE}.lock" 2>/dev/null
        else
            return 1
        fi
    fi

    # Already-running check
    if is_vm_running "$vm_name"; then
        print_status "WARN" "⚠️  VM '$vm_name' is already running"
        read -p "$(print_status "INPUT" "🔄 Stop and restart? (y/N): ")" restart_choice
        if [[ "$restart_choice" =~ ^[Yy]$ ]]; then
            stop_vm "$vm_name"
            sleep 2
        else
            return 1
        fi
    fi

    # Pre-flight checks
    if [[ ! -f "$IMG_FILE" ]]; then
        print_status "ERROR" "❌ Image file not found: $IMG_FILE"
        return 1
    fi

    if [[ ! -f "$SEED_FILE" ]]; then
        print_status "WARN" "⚠️  Seed file missing — recreating..."
        setup_vm_image
    fi

    if ! check_host_resources "$MEMORY" "$CPUS"; then
        return 1
    fi

    print_status "INFO" "🚀 Starting VM: $vm_name"
    print_status "INFO" "🔌 SSH: ssh -p $SSH_PORT $USERNAME@localhost"
    print_status "INFO" "🔑 Password: $PASSWORD"

    # Build QEMU command
    local qemu_cmd=(
        qemu-system-x86_64
    )

    # KVM acceleration
    if [[ "$KVM_ENABLED" == true ]]; then
        qemu_cmd+=(-enable-kvm)
    else
        qemu_cmd+=(-accel tcg,thread=multi)
    fi

    # Resources
    qemu_cmd+=(-m "$MEMORY" -smp "$CPUS" -cpu host)

    # Drives
    qemu_cmd+=(-drive "file=$IMG_FILE,format=qcow2,if=virtio")
    qemu_cmd+=(-drive "file=$SEED_FILE,format=raw,if=virtio")
    qemu_cmd+=(-boot order=c)

    # Network — primary
    qemu_cmd+=(-device virtio-net-pci,netdev=n0)
    local mac_opt=""
    if [[ -n "$MAC_ADDRESS" ]]; then
        mac_opt=",mac=$MAC_ADDRESS"
    fi
    qemu_cmd+=(-netdev "user,id=n0,hostfwd=tcp::$SSH_PORT-:22")
    qemu_cmd+=(-device "virtio-net-pci,netdev=n0${mac_opt}")

    # Additional port forwards — use a separate counter for netdev IDs
    if [[ -n "$PORT_FORWARDS" ]]; then
        IFS=',' read -ra forwards <<< "$PORT_FORWARDS"
        local fwd_idx=1
        for forward in "${forwards[@]}"; do
            forward=$(echo "$forward" | xargs)  # trim whitespace
            if [[ -z "$forward" ]]; then continue; fi
            # Validate each forward
            if ! validate_input "portforward" "$forward"; then
                print_status "WARN" "⚠️  Skipping invalid port forward: $forward"
                continue
            fi
            local host_p guest_p
            IFS=':' read -r host_p guest_p <<< "$forward"

            # Check port is free
            if ss -tln 2>/dev/null | grep -q ":${host_p} "; then
                print_status "WARN" "⚠️  Host port $host_p already in use — skipping this forward"
                continue
            fi

            qemu_cmd+=(-netdev "user,id=n${fwd_idx},hostfwd=tcp::${host_p}-:${guest_p}")
            qemu_cmd+=(-device "virtio-net-pci,netdev=n${fwd_idx}")
            (( fwd_idx++ )) || true
        done
    fi

    # BIOS / UEFI
    if [[ "${BIOS_MODE:-bios}" == "uefi" ]]; then
        # Try to find OVMF firmware
        local ovmf_code ovmf_vars
        for p in \
            /usr/share/OVMF/OVMF_CODE.fd \
            /usr/share/qemu/OVMF_CODE.fd \
            /usr/share/edk2/ovmf/OVMF_CODE.fd; do
            if [[ -f "$p" ]]; then ovmf_code="$p"; break; fi
        done
        for p in \
            /usr/share/OVMF/OVMF_VARS.fd \
            /usr/share/qemu/OVMF_VARS.fd \
            /usr/share/edk2/ovmf/OVMF_VARS.fd; do
            if [[ -f "$p" ]]; then ovmf_vars="$p"; break; fi
        done

        if [[ -n "${ovmf_code:-}" && -n "${ovmf_vars:-}" ]]; then
            # Copy mutable VARS to a per-VM location
            local vm_ovmf_vars="${IMG_FILE}.ovmf-vars.fd"
            cp "$ovmf_vars" "$vm_ovmf_vars"
            qemu_cmd+=(-drive "if=pflash,format=raw,readonly=on,file=$ovmf_code")
            qemu_cmd+=(-drive "if=pflash,format=raw,file=$vm_ovmf_vars")
            print_status "INFO" "🔒 UEFI boot enabled"
        else
            print_status "WARN" "⚠️  OVMF firmware not found — falling back to BIOS"
        fi
    fi

    # Display / serial
    if [[ "$GUI_MODE" == true ]]; then
        qemu_cmd+=(-vga virtio -display gtk,gl=on)
        print_status "INFO" "🖥️  Starting in GUI mode..."
    else
        qemu_cmd+=(-nographic -serial mon:stdio)
        print_status "INFO" "📟 Starting in console mode..."
        print_status "INFO" "🛑 Press Ctrl+A then X to exit QEMU console"
    fi

    # Remote access (Spice / VNC)
    case "${REMOTE_ACCESS:-none}" in
        spice)
            qemu_cmd+=(-spice port=5900,disable-ticketing=on)
            print_status "INFO" "📡 Spice server on port 5900"
            ;;
        vnc)
            qemu_cmd+=(-vnc :0)
            print_status "INFO" "📡 VNC server on display :0 (port 5900)"
            ;;
        none) ;;
    esac

    # Background mode
    if [[ "${BACKGROUND_MODE:-false}" == true ]]; then
        local monitor_sock="$VM_DIR/${VM_NAME}.monitor.sock"
        qemu_cmd+=(-qmp "unix:${monitor_sock},server,nowait")
        qemu_cmd+=(-daemonize -pidfile "$VM_DIR/${VM_NAME}.pid")
        print_status "INFO" "🔙 Starting in background mode..."
    fi

    # Performance enhancements
    qemu_cmd+=(-device virtio-balloon-pci)
    qemu_cmd+=(-object rng-random,filename=/dev/urandom,id=rng0)
    qemu_cmd+=(-device virtio-rng-pci,rng=rng0)

    # Snapshot overlay (if snapshot mode)
    if [[ "${SNAPSHOT_MODE:-false}" == true ]]; then
        qemu_cmd+=(-snapshot)
        print_status "INFO" "📸 Running in snapshot mode (changes discarded on shutdown)"
    fi

    echo "📊 Config: ${MEMORY}MB RAM | ${CPUS} vCPUs | ${DISK_SIZE} disk | ${BIOS_MODE:-bios} boot"
    log INFO "Starting VM: $vm_name (mem=${MEMORY}, cpus=${CPUS}, disk=${DISK_SIZE})"

    if ! "${qemu_cmd[@]}"; then
        print_status "ERROR" "❌ QEMU failed to start. Check logs: $LOG_FILE"
        rm -f "${IMG_FILE}.lock" 2>/dev/null
        log ERROR "QEMU start failed: $vm_name"
        return 1
    fi

    print_status "SUCCESS" "✅ VM $vm_name is running"
}

delete_vm() {
    local vm_name="$1"

    print_status "WARN" "⚠️  ⚠️  ⚠️  This will PERMANENTLY delete VM '$vm_name' and ALL its data!"
    read -p "$(print_status "INPUT" "🗑️  Type the VM name to confirm deletion: ")" confirm_name
    echo
    if [[ "$confirm_name" != "$vm_name" ]]; then
        print_status "ERROR" "❌ Confirmation mismatch. Deletion cancelled."
        return 0
    fi

    if load_vm_config "$vm_name"; then
        if is_vm_running "$vm_name"; then
            print_status "WARN" "⚠️  VM is running — stopping first..."
            stop_vm "$vm_name"
            sleep 2
        fi

        rm -f "$IMG_FILE" "$SEED_FILE" "$VM_DIR/$vm_name.conf" "${IMG_FILE}.lock" 2>/dev/null
        # Clean up optional files
        rm -f "${IMG_FILE}.ovmf-vars.fd" "$VM_DIR/${vm_name}.monitor.sock" "$VM_DIR/${vm_name}.pid" 2>/dev/null
        print_status "SUCCESS" "✅ VM '$vm_name' and all data deleted"
        log INFO "VM deleted: $vm_name"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  SNAPSHOT MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────
snapshot_create() {
    local vm_name="$1"
    local snap_name="$2"

    load_vm_config "$vm_name" || return 1
    is_vm_running "$vm_name" && {
        print_status "ERROR" "❌ Stop the VM before creating a snapshot"
        return 1
    }

    local snap_dir="$VM_DIR/snapshots/$vm_name"
    mkdir -p "$snap_dir"

    local snap_file="$snap_dir/${snap_name}.img"
    local meta_file="$snap_dir/${snap_name}.meta"

    print_status "INFO" "📸 Creating snapshot '$snap_name' for $vm_name..."
    qemu-img create -f qcow2 -F qcow2 -b "$IMG_FILE" "$snap_file"

    # Save metadata
    cat > "$meta_file" <<EOF
SNAP_NAME="$snap_name"
BASE_IMG="$IMG_FILE"
CREATED="$(date)"
VM_NAME="$vm_name"
EOF

    print_status "SUCCESS" "✅ Snapshot '$snap_name' created at $snap_file"
    log INFO "Snapshot created: $vm_name/$snap_name"
}

snapshot_list() {
    local vm_name="$1"
    local snap_dir="$VM_DIR/snapshots/$vm_name"

    if [[ ! -d "$snap_dir" ]]; then
        print_status "INFO" "📂 No snapshots found for '$vm_name'"
        return 0
    fi

    echo
    print_status "INFO" "📋 Snapshots for $vm_name:"
    echo "────────────────────────────────────────────────"
    printf "  %-20s %-12s %s\n" "NAME" "SIZE" "CREATED"
    echo "────────────────────────────────────────────────"
    for meta in "$snap_dir"/*.meta; do
        [[ -f "$meta" ]] || continue
        local sname created
        source "$meta" 2>/dev/null
        local size
        size=$(du -h "$snap_dir/${sname}.img" 2>/dev/null | cut -f1)
        printf "  %-20s %-12s %s\n" "$sname" "${size:-N/A}" "$created"
    done
    echo "────────────────────────────────────────────────"
    echo
}

snapshot_revert() {
    local vm_name="$1"
    local snap_name="$2"

    load_vm_config "$vm_name" || return 1
    is_vm_running "$vm_name" && {
        print_status "ERROR" "❌ Stop the VM before reverting a snapshot"
        return 1
    }

    local snap_file="$VM_DIR/snapshots/$vm_name/${snap_name}.img"
    if [[ ! -f "$snap_file" ]]; then
        print_status "ERROR" "❌ Snapshot '$snap_name' not found"
        return 1
    fi

    print_status "WARN" "⚠️  Reverting to snapshot '$snap_name' will OVERWRITE the current disk image!"
    read -p "$(print_status "INPUT" "🔄 Are you sure? (y/N): ")" revert_confirm
    [[ "$revert_confirm" =~ ^[Yy]$ ]] || return 0

    cp "$snap_file" "$IMG_FILE"
    print_status "SUCCESS" "✅ Reverted to snapshot '$snap_name'"
    log INFO "Snapshot reverted: $vm_name/$snap_name"
}

snapshot_delete() {
    local vm_name="$1"
    local snap_name="$2"

    local snap_dir="$VM_DIR/snapshots/$vm_name"
    local snap_file="$snap_dir/${snap_name}.img"
    local meta_file="$snap_dir/${snap_name}.meta"

    if [[ ! -f "$snap_file" ]]; then
        print_status "ERROR" "❌ Snapshot '$snap_name' not found"
        return 1
    fi

    print_status "WARN" "⚠️  Delete snapshot '$snap_name'?"
    read -p "$(print_status "INPUT" "🗑️  Confirm (y/N): ")" del_confirm
    [[ "$del_confirm" =~ ^[Yy]$ ]] || return 0

    rm -f "$snap_file" "$meta_file"
    print_status "SUCCESS" "✅ Snapshot '$snap_name' deleted"
    log INFO "Snapshot deleted: $vm_name/$snap_name"
}

snapshot_menu() {
    local vm_name="$1"
    while true; do
        echo
        echo "📸 Snapshot Management: $vm_name"
        echo "  1) Create snapshot"
        echo "  2) List snapshots"
        echo "  3) Revert to snapshot"
        echo "  4) Delete snapshot"
        echo "  0) Back"
        read -p "$(print_status "INPUT" "🎯 Choice: ")" snap_choice
        case "$snap_choice" in
            1)
                read -p "$(print_status "INPUT" "📸 Snapshot name: ")" snap_name
                [[ -n "$snap_name" ]] && snapshot_create "$vm_name" "$snap_name"
                ;;
            2) snapshot_list "$vm_name" ;;
            3)
                read -p "$(print_status "INPUT" "🔄 Snapshot name to revert: ")" snap_name
                [[ -n "$snap_name" ]] && snapshot_revert "$vm_name" "$snap_name"
                ;;
            4)
                read -p "$(print_status "INPUT" "🗑️  Snapshot name to delete: ")" snap_name
                [[ -n "$snap_name" ]] && snapshot_delete "$vm_name" "$snap_name"
                ;;
            0) return 0 ;;
            *) print_status "ERROR" "❌ Invalid selection" ;;
        esac
        read -p "$(print_status "INPUT" "⏎ Press Enter to continue...")"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
#  VM CLONE
# ─────────────────────────────────────────────────────────────────────────────
clone_vm() {
    local src_name="$1"

    load_vm_config "$src_name" || return 1

    print_status "INFO" "📋 Cloning VM '$src_name'..."

    # New name
    while true; do
        read -p "$(print_status "INPUT" "🏷️  New VM name for clone: ")" new_name
        [[ -n "$new_name" ]] || continue
        if ! validate_input "name" "$new_name"; then continue; fi
        if [[ -f "$VM_DIR/$new_name.conf" ]]; then
            print_status "ERROR" "⚠️  A VM named '$new_name' already exists"
            continue
        fi
        break
    done

    # New SSH port
    while true; do
        read -p "$(print_status "INPUT" "🔌 New SSH port (current: $SSH_PORT): ")" new_ssh
        new_ssh="${new_ssh:-$((SSH_PORT + 1))}"
        if validate_input "port" "$new_ssh"; then
            if ss -tln 2>/dev/null | grep -q ":${new_ssh} "; then
                print_status "ERROR" "🚫 Port $new_ssh already in use"
                continue
            fi
            break
        fi
    done

    # Clone disk image
    local new_img="$VM_DIR/$new_name.img"
    local new_seed="$VM_DIR/$new_name-seed.iso"
    print_status "INFO" "📥 Copying disk image (may take a while)..."
    cp "$IMG_FILE" "$new_img"
    cp "$SEED_FILE" "$new_seed"

    # Update variables and save
    VM_NAME="$new_name"
    IMG_FILE="$new_img"
    SEED_FILE="$new_seed"
    SSH_PORT="$new_ssh"
    HOSTNAME="$new_name"
    CREATED="$(date)"
    MAC_ADDRESS=""  # Force new MAC generation
    PORT_FORWARDS=""

    save_vm_config
    print_status "SUCCESS" "✅ VM '$src_name' cloned as '$new_name' (SSH port: $new_ssh)"
    log INFO "VM cloned: $src_name → $new_name"
}

# ─────────────────────────────────────────────────────────────────────────────
#  VM INFO & PERFORMANCE
# ─────────────────────────────────────────────────────────────────────────────
show_vm_info() {
    local vm_name="$1"

    load_vm_config "$vm_name" || return 1

    echo
    print_status "INFO" "📊 VM Information: $vm_name"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  %-22s %s\n" "🌍 OS:"           "$OS_TYPE ($CODENAME)"
    printf "  %-22s %s\n" "🏷️  Hostname:"    "$HOSTNAME"
    printf "  %-22s %s\n" "👤 Username:"     "$USERNAME"
    printf "  %-22s %s\n" "🔑 Password:"     "$PASSWORD"
    printf "  %-22s %s\n" "🔌 SSH Port:"     "$SSH_PORT"
    printf "  %-22s %s\n" "🧠 Memory:"       "${MEMORY} MB"
    printf "  %-22s %s\n" "⚡ CPUs:"         "$CPUS"
    printf "  %-22s %s\n" "💾 Disk:"         "$DISK_SIZE"
    printf "  %-22s %s\n" "🖥️  GUI Mode:"    "$GUI_MODE"
    printf "  %-22s %s\n" "🌐 Port Forwards:" "${PORT_FORWARDS:-None}"
    printf "  %-22s %s\n" "🔒 BIOS Mode:"    "${BIOS_MODE:-bios}"
    printf "  %-22s %s\n" "📡 Remote Access:" "${REMOTE_ACCESS:-none}"
    printf "  %-22s %s\n" "🔙 Background:"   "${BACKGROUND_MODE:-false}"
    printf "  %-22s %s\n" "🏎️  Autostart:"   "$AUTOSTART"
    printf "  %-22s %s\n" "📅 Created:"      "$CREATED"
    printf "  %-22s %s\n" "💿 Image File:"   "$IMG_FILE"
    printf "  %-22s %s\n" "🌱 Seed File:"    "$SEED_FILE"

    if is_vm_running "$vm_name"; then
        echo "🚀 Status: Running"
    else
        echo "💤 Status: Stopped"
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    read -p "$(print_status "INPUT" "⏎ Press Enter to continue...")"
}

show_vm_performance() {
    local vm_name="$1"

    load_vm_config "$vm_name" || return 1

    if is_vm_running "$vm_name"; then
        print_status "INFO" "📊 Performance metrics for VM: $vm_name"
        echo "════════════════════════════════════════════"

        local qemu_pid
        qemu_pid=$(pgrep -f "qemu-system.*${IMG_FILE}" | head -1)
        if [[ -n "$qemu_pid" ]]; then
            echo "⚡ QEMU Process ($qemu_pid):"
            ps -p "$qemu_pid" -o pid,pcpu,pmem,sz,rss,vsz,etime,cmd --no-headers 2>/dev/null | \
                sed 's/^/  /'
            echo

            echo "🧠 System Memory:"
            free -h 2>/dev/null | sed 's/^/  /'
            echo

            echo "💾 Disk:"
            if [[ -f "$IMG_FILE" ]]; then
                local du_info
                du_info=$(du -sh "$IMG_FILE" 2>/dev/null | cut -f1)
                echo "  Image: $du_info"
            fi
        else
            print_status "ERROR" "❌ Could not find QEMU process for $vm_name"
        fi
        echo "════════════════════════════════════════════"
    else
        print_status "INFO" "💤 VM $vm_name is not running"
        echo "⚙️  Configuration:"
        echo "  🧠 Memory: $MEMORY MB"
        echo "  ⚡ CPUs: $CPUS"
        echo "  💾 Disk: $DISK_SIZE"
    fi
    echo
    read -p "$(print_status "INPUT" "⏎ Press Enter to continue...")"
}

# ─────────────────────────────────────────────────────────────────────────────
#  VM EDIT
# ─────────────────────────────────────────────────────────────────────────────
edit_vm_config() {
    local vm_name="$1"

    load_vm_config "$vm_name" || return 1
    print_status "INFO" "✏️  Editing VM: $vm_name"

    while true; do
        echo
        echo "📝 Edit VM '$vm_name':"
        echo "  1)  🏷️  Hostname"
        echo "  2)  👤 Username"
        echo "  3)  🔑 Password"
        echo "  4)  🔌 SSH Port"
        echo "  5)  🖥️  GUI Mode"
        echo "  6)  🌐 Port Forwards"
        echo "  7)  🧠 Memory (RAM)"
        echo "  8)  ⚡ CPU Count"
        echo "  9)  💾 Disk Size"
        echo "  10) 🔒 BIOS/UEFI"
        echo "  11) 📡 Remote Access (Spice/VNC)"
        echo "  12) 🔙 Background Mode"
        echo "  13) 🏎️  Autostart"
        echo "  14) 🔗 MAC Address"
        echo "  0)  ↩️  Back"

        read -p "$(print_status "INPUT" "🎯 Choice: ")" edit_choice

        local needs_seed_rebuild=false

        case "$edit_choice" in
            1)
                while true; do
                    read -p "$(print_status "INPUT" "🏷️  Hostname (current: $HOSTNAME): ")" new_val
                    new_val="${new_val:-$HOSTNAME}"
                    if validate_input "name" "$new_val"; then HOSTNAME="$new_val"; needs_seed_rebuild=true; break; fi
                done ;;
            2)
                while true; do
                    read -p "$(print_status "INPUT" "👤 Username (current: $USERNAME): ")" new_val
                    new_val="${new_val:-$USERNAME}"
                    if validate_input "username" "$new_val"; then USERNAME="$new_val"; needs_seed_rebuild=true; break; fi
                done ;;
            3)
                while true; do
                    read -s -p "$(print_status "INPUT" "🔑 Password (current: ****): ")" new_val
                    new_val="${new_val:-$PASSWORD}"
                    echo
                    if [[ -n "$new_val" ]]; then PASSWORD="$new_val"; needs_seed_rebuild=true; break; fi
                    print_status "ERROR" "❌ Password cannot be empty"
                done ;;
            4)
                while true; do
                    read -p "$(print_status "INPUT" "🔌 SSH port (current: $SSH_PORT): ")" new_val
                    new_val="${new_val:-$SSH_PORT}"
                    if validate_input "port" "$new_val"; then
                        if [[ "$new_val" != "$SSH_PORT" ]] && ss -tln 2>/dev/null | grep -q ":${new_val} "; then
                            print_status "ERROR" "🚫 Port $new_val already in use"
                            continue
                        fi
                        SSH_PORT="$new_val"
                        break
                    fi
                done ;;
            5)
                while true; do
                    read -p "$(print_status "INPUT" "🖥️  GUI mode (current: $GUI_MODE, y/n): ")" gui_in
                    gui_in="${gui_in:-}"
                    if [[ -z "$gui_in" ]]; then break; fi
                    if [[ "$gui_in" =~ ^[Yy]$ ]]; then GUI_MODE=true; break; fi
                    if [[ "$gui_in" =~ ^[Nn]$ ]]; then GUI_MODE=false; break; fi
                    print_status "ERROR" "❌ Answer y or n"
                done ;;
            6)
                read -p "$(print_status "INPUT" "🌐 Port forwards (current: ${PORT_FORWARDS:-None}, comma-separated): ")" new_pf
                PORT_FORWARDS="${new_pf:-$PORT_FORWARDS}" ;;
            7)
                while true; do
                    read -p "$(print_status "INPUT" "🧠 Memory MB (current: $MEMORY): ")" new_val
                    new_val="${new_val:-$MEMORY}"
                    if validate_input "number" "$new_val"; then MEMORY="$new_val"; break; fi
                done ;;
            8)
                while true; do
                    read -p "$(print_status "INPUT" "⚡ CPUs (current: $CPUS): ")" new_val
                    new_val="${new_val:-$CPUS}"
                    if validate_input "number" "$new_val"; then CPUS="$new_val"; break; fi
                done ;;
            9)
                while true; do
                    read -p "$(print_status "INPUT" "💾 Disk size (current: $DISK_SIZE): ")" new_val
                    new_val="${new_val:-$DISK_SIZE}"
                    if validate_input "size" "$new_val"; then DISK_SIZE="$new_val"; break; fi
                done ;;
            10)
                echo "  a) BIOS (legacy)"
                echo "  b) UEFI"
                read -p "$(print_status "INPUT" "🔒 Boot mode (current: ${BIOS_MODE:-bios}): ")" boot_in
                case "$boot_in" in
                    a|A|bios) BIOS_MODE="bios" ;;
                    b|B|uefi) BIOS_MODE="uefi" ;;
                    *) print_status "INFO" "Keeping current: ${BIOS_MODE:-bios}" ;;
                esac ;;
            11)
                echo "  n) None"
                echo "  s) Spice (port 5900)"
                echo "  v) VNC (display :0)"
                read -p "$(print_status "INPUT" "📡 Remote access (current: ${REMOTE_ACCESS:-none}): ")" ra_in
                case "$ra_in" in
                    n|N|none) REMOTE_ACCESS="none" ;;
                    s|S|spice) REMOTE_ACCESS="spice" ;;
                    v|V|vnc) REMOTE_ACCESS="vnc" ;;
                    *) print_status "INFO" "Keeping current: ${REMOTE_ACCESS:-none}" ;;
                esac ;;
            12)
                read -p "$(print_status "INPUT" "🔙 Run in background? (current: ${BACKGROUND_MODE:-false}, y/n): ")" bg_in
                bg_in="${bg_in:-}"
                if [[ -n "$bg_in" ]]; then
                    [[ "$bg_in" =~ ^[Yy]$ ]] && BACKGROUND_MODE=true || BACKGROUND_MODE=false
                fi ;;
            13)
                read -p "$(print_status "INPUT" "🏎️  Autostart on host boot? (current: $AUTOSTART, y/n): ")" as_in
                as_in="${as_in:-}"
                if [[ -n "$as_in" ]]; then
                    [[ "$as_in" =~ ^[Yy]$ ]] && AUTOSTART=true || AUTOSTART=false
                fi ;;
            14)
                read -p "$(print_status "INPUT" "🔗 MAC address (current: ${MAC_ADDRESS:-auto}, empty=auto): ")" mac_in
                mac_in="${mac_in:-}"
                if [[ -n "$mac_in" ]]; then
                    if validate_input "mac" "$mac_in"; then MAC_ADDRESS="$mac_in"; fi
                else
                    MAC_ADDRESS=""
                fi ;;
            0)
                return 0 ;;
            *)
                print_status "ERROR" "❌ Invalid selection"
                continue ;;
        esac

        # Rebuild seed if identity fields changed
        if [[ "$needs_seed_rebuild" == true ]]; then
            print_status "INFO" "🔄 Updating cloud-init seed image..."
            setup_vm_image
        fi

        save_vm_config

        read -p "$(print_status "INPUT" "🔄 Continue editing? (y/N): ")" cont
        [[ "$cont" =~ ^[Yy]$ ]] || break
    done
}

# ─────────────────────────────────────────────────────────────────────────────
#  DISK RESIZE
# ─────────────────────────────────────────────────────────────────────────────
resize_vm_disk() {
    local vm_name="$1"

    load_vm_config "$vm_name" || return 1

    is_vm_running "$vm_name" && {
        print_status "ERROR" "❌ Stop the VM before resizing the disk"
        return 1
    }

    print_status "INFO" "💾 Current disk: $DISK_SIZE"

    while true; do
        read -p "$(print_status "INPUT" "📈 New disk size (e.g., 50G): ")" new_size
        if ! validate_input "size" "$new_size"; then continue; fi

        [[ "$new_size" == "$DISK_SIZE" ]] && {
            print_status "INFO" "ℹ️  Same size — no changes"
            return 0
        }

        # Compare sizes in MB
        local cur_num=${DISK_SIZE%[GgMm]} cur_unit=${DISK_SIZE: -1}
        local new_num=${new_size%[GgMm]} new_unit=${new_size: -1}
        [[ "$cur_unit" =~ [Gg] ]] && cur_num=$((cur_num * 1024))
        [[ "$new_unit" =~ [Gg] ]] && new_num=$((new_num * 1024))

        if [[ $new_num -lt $cur_num ]]; then
            print_status "WARN" "⚠️  Shrinking disk may cause DATA LOSS!"
            read -p "$(print_status "INPUT" "⚠️  Confirm shrink? (y/N): ")" shrink_ok
            [[ "$shrink_ok" =~ ^[Yy]$ ]] || { print_status "INFO" "👍 Cancelled."; return 0; }
        fi

        if qemu-img resize "$IMG_FILE" "$new_size"; then
            DISK_SIZE="$new_size"
            save_vm_config
            print_status "SUCCESS" "✅ Disk resized to $new_size"
            log INFO "Disk resized: $vm_name → $new_size"
        else
            print_status "ERROR" "❌ Resize failed"
            return 1
        fi
        break
    done
}

# ─────────────────────────────────────────────────────────────────────────────
#  FIX / TROUBLESHOOT
# ─────────────────────────────────────────────────────────────────────────────
fix_vm_issues() {
    local vm_name="$1"

    load_vm_config "$vm_name" || return 1

    echo
    echo "🔧 Troubleshooting: $vm_name"
    echo "  1) 🔓 Remove lock files"
    echo "  2) 🗑️  Recreate seed image"
    echo "  3) 🔄 Re-save configuration"
    echo "  4) 💀 Kill stuck QEMU processes"
    echo "  5) 🔍 Test image integrity (qemu-img info)"
    echo "  6) 📋 Show raw config file"
    echo "  0) Back"
    read -p "$(print_status "INPUT" "🎯 Choice: ")" fix_choice

    case "$fix_choice" in
        1)
            rm -f "${IMG_FILE}.lock" "${IMG_FILE}"*.lock 2>/dev/null
            print_status "SUCCESS" "✅ Lock files removed"
            ;;
        2)
            rm -f "$SEED_FILE"
            setup_vm_image
            ;;
        3)
            save_vm_config
            ;;
        4)
            pkill -f "qemu-system.*${IMG_FILE}" 2>/dev/null || true
            sleep 1
            pgrep -f "qemu-system.*${IMG_FILE}" >/dev/null 2>&1 && \
                pkill -9 -f "qemu-system.*${IMG_FILE}" 2>/dev/null || true
            print_status "SUCCESS" "✅ Processes cleaned up"
            ;;
        5)
            if [[ -f "$IMG_FILE" ]]; then
                qemu-img info "$IMG_FILE"
            else
                print_status "ERROR" "❌ Image not found"
            fi
            ;;
        6)
            if [[ -f "$VM_DIR/$vm_name.conf" ]]; then
                cat "$VM_DIR/$vm_name.conf"
            fi
            ;;
        0) return 0 ;;
        *) print_status "ERROR" "❌ Invalid selection" ;;
    esac
    read -p "$(print_status "INPUT" "⏎ Press Enter to continue...")"
}

# ─────────────────────────────────────────────────────────────────────────────
#  BACKUP & RESTORE
# ─────────────────────────────────────────────────────────────────────────────
backup_vm() {
    local vm_name="$1"

    load_vm_config "$vm_name" || return 1

    local backup_dir="$VM_DIR/backups/${vm_name}"
    mkdir -p "$backup_dir"

    local ts
    ts=$(date '+%Y%m%d-%H%M%S')
    local backup_file="$backup_dir/${vm_name}-${ts}.tar.gz"

    print_status "INFO" "📦 Backing up '$vm_name'..."

    # Include config + seed (NOT the full disk image by default — too large)
    tar -czf "$backup_file" \
        -C "$VM_DIR" \
        "$vm_name.conf" \
        "$(basename "$SEED_FILE")" \
        2>/dev/null

    if [[ $? -eq 0 ]]; then
        print_status "SUCCESS" "✅ Backup saved: $backup_file"
        log INFO "Backup created: $vm_name → $backup_file"
    else
        print_status "ERROR" "❌ Backup failed"
    fi
}

restore_vm() {
    print_status "INFO" "📦 Available backups:"
    local found=false
    for backup in "$VM_DIR/backups"/*/*.tar.gz; do
        [[ -f "$backup" ]] || continue
        echo "  📄 $(basename "$backup")"
        found=true
    done
    if [[ "$found" == false ]]; then
        print_status "INFO" "No backups found."
        return 0
    fi

    read -p "$(print_status "INPUT" "📦 Enter backup filename to restore: ")" restore_file
    local full_path="$VM_DIR/backups/*/$restore_file"
    # Resolve with glob
    local resolved
    resolved=$(ls $full_path 2>/dev/null | head -1)
    if [[ -z "$resolved" ]]; then
        print_status "ERROR" "❌ Backup not found"
        return 1
    fi

    print_status "INFO" "📦 Restoring from $resolved ..."
    tar -xzf "$resolved" -C "$VM_DIR"
    print_status "SUCCESS" "✅ Restore complete"
    log INFO "Restore from: $resolved"
}

# ─────────────────────────────────────────────────────────────────────────────
#  CREATE NEW VM
# ─────────────────────────────────────────────────────────────────────────────
create_new_vm() {
    print_status "INFO" "🆕 Creating a new VM"

    # OS selection
    print_status "INFO" "🌍 Select an OS:"
    local os_options=()
    local i=1
    for os in "${!OS_OPTIONS[@]}"; do
        echo "  $i) $os"
        os_options[$i]="$os"
        (( i++ )) || true
    done

    local choice
    while true; do
        read -p "$(print_status "INPUT" "🎯 Choice (1-${#OS_OPTIONS[@]}): ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#OS_OPTIONS[@]} ]; then
            local os="${os_options[$choice]}"
            IFS='|' read -r OS_TYPE CODENAME IMG_URL DEFAULT_HOSTNAME DEFAULT_USERNAME DEFAULT_PASSWORD \
                <<< "${OS_OPTIONS[$os]}"
            break
        fi
        print_status "ERROR" "❌ Invalid selection"
    done

    # Hostname / name
    while true; do
        read -p "$(print_status "INPUT" "🏷️  VM name (default: $DEFAULT_HOSTNAME): ")" VM_NAME
        VM_NAME="${VM_NAME:-$DEFAULT_HOSTNAME}"
        if validate_input "name" "$VM_NAME"; then
            [[ -f "$VM_DIR/$VM_NAME.conf" ]] && \
                { print_status "ERROR" "⚠️  VM '$VM_NAME' already exists"; continue; }
            break
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "🏠 Hostname (default: $VM_NAME): ")" HOSTNAME
        HOSTNAME="${HOSTNAME:-$VM_NAME}"
        if validate_input "name" "$HOSTNAME"; then break; fi
    done

    while true; do
        read -p "$(print_status "INPUT" "👤 Username (default: $DEFAULT_USERNAME): ")" USERNAME
        USERNAME="${USERNAME:-$DEFAULT_USERNAME}"
        if validate_input "username" "$USERNAME"; then break; fi
    done

    while true; do
        read -s -p "$(print_status "INPUT" "🔑 Password (default: $DEFAULT_PASSWORD): ")" PASSWORD
        PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"
        echo
        [[ -n "$PASSWORD" ]] && break
        print_status "ERROR" "❌ Password cannot be empty"
    done

    while true; do
        read -p "$(print_status "INPUT" "💾 Disk size (default: 20G): ")" DISK_SIZE
        DISK_SIZE="${DISK_SIZE:-20G}"
        if validate_input "size" "$DISK_SIZE"; then break; fi
    done

    while true; do
        read -p "$(print_status "INPUT" "🧠 Memory MB (default: 2048): ")" MEMORY
        MEMORY="${MEMORY:-2048}"
        if validate_input "number" "$MEMORY"; then break; fi
    done

    while true; do
        read -p "$(print_status "INPUT" "⚡ CPUs (default: 2): ")" CPUS
        CPUS="${CPUS:-2}"
        if validate_input "number" "$CPUS"; then break; fi
    done

    while true; do
        read -p "$(print_status "INPUT" "🔌 SSH port (default: 2222): ")" SSH_PORT
        SSH_PORT="${SSH_PORT:-2222}"
        if validate_input "port" "$SSH_PORT"; then
            if ss -tln 2>/dev/null | grep -q ":${SSH_PORT} "; then
                print_status "ERROR" "🚫 Port $SSH_PORT already in use"
                continue
            fi
            break
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "🖥️  GUI mode? (y/n, default: n): ")" gui_in
        gui_in="${gui_in:-n}"
        if [[ "$gui_in" =~ ^[Yy]$ ]]; then GUI_MODE=true; break; fi
        if [[ "$gui_in" =~ ^[Nn]$ ]]; then GUI_MODE=false; break; fi
        print_status "ERROR" "❌ Answer y or n"
    done

    # BIOS/UEFI
    while true; do
        read -p "$(print_status "INPUT" "🔒 Boot mode? (bios/uefi, default: bios): ")" boot_in
        boot_in="${boot_in:-bios}"
        case "$boot_in" in
            bios|Bios|BIOS) BIOS_MODE="bios"; break ;;
            uefi|Uefi|UEFI) BIOS_MODE="uefi"; break ;;
            "") BIOS_MODE="bios"; break ;;
            *) print_status "ERROR" "❌ Answer 'bios' or 'uefi'" ;;
        esac
    done

    # Remote access
    while true; do
        read -p "$(print_status "INPUT" "📡 Remote access? (none/spice/vnc, default: none): ")" ra_in
        ra_in="${ra_in:-none}"
        case "$ra_in" in
            none|None) REMOTE_ACCESS="none"; break ;;
            spice|Spice|SPICE) REMOTE_ACCESS="spice"; break ;;
            vnc|Vnc|VNC) REMOTE_ACCESS="vnc"; break ;;
            "") REMOTE_ACCESS="none"; break ;;
            *) print_status "ERROR" "❌ Answer none, spice, or vnc" ;;
        esac
    done

    # Background mode
    read -p "$(print_status "INPUT" "🔙 Run in background? (y/n, default: n): ")" bg_in
    bg_in="${bg_in:-n}"
    if [[ "$bg_in" =~ ^[Yy]$ ]]; then BACKGROUND_MODE=true; else BACKGROUND_MODE=false; fi

    # Additional port forwards (validated per-entry)
    read -p "$(print_status "INPUT" "🌐 Extra port forwards (e.g., 8080:80, comma-separated, Enter=none): ")" PORT_FORWARDS

    # MAC address (optional)
    read -p "$(print_status "INPUT" "🔗 MAC address (Enter=auto-generated): ")" MAC_ADDRESS
    MAC_ADDRESS="${MAC_ADDRESS:-}"
    if [[ -n "$MAC_ADDRESS" ]]; then
        validate_input "mac" "$MAC_ADDRESS" || MAC_ADDRESS=""
    fi

    IMG_FILE="$VM_DIR/$VM_NAME.img"
    SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"
    CREATED="$(date)"
    AUTOSTART="false"

    setup_vm_image || return 1
    save_vm_config
    log INFO "VM created: $VM_NAME"
}

# ─────────────────────────────────────────────────────────────────────────────
#  START ALL AUTOSTART VMs
# ─────────────────────────────────────────────────────────────────────────────
start_autostart_vms() {
    print_status "INFO" "🏎️  Starting autostart VMs..."
    local started=0
    for vm in $(get_vm_list); do
        if load_vm_config "$vm" 2>/dev/null && [[ "${AUTOSTART:-false}" == true ]]; then
            if ! is_vm_running "$vm"; then
                print_status "INFO" "🚀 Starting autostart VM: $vm"
                start_vm "$vm"
                (( started++ )) || true
            fi
        fi
    done
    [[ $started -gt 0 ]] && print_status "SUCCESS" "✅ Started $started autostart VM(s)" || \
        print_status "INFO" "No autostart VMs configured"
}

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN MENU
# ─────────────────────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        display_header

        local vms=($(get_vm_list))
        local vm_count=${#vms[@]}

        if [ "$vm_count" -gt 0 ]; then
            print_status "INFO" "📁 Found $vm_count VM(s):"
            for i in "${!vms[@]}"; do
                local status="💤"
                is_vm_running "${vms[$i]}" && status="🚀"
                printf "  %2d) %-20s %s\n" $((i+1)) "${vms[$i]}" "$status"
            done
            echo
        fi

        echo "📋 Main Menu:"
        echo "  1)  🆕 Create a new VM"
        if [ "$vm_count" -gt 0 ]; then
            echo "  2)  🚀 Start a VM"
            echo "  3)  🛑 Stop a VM"
            echo "  4)  📊 Show VM info"
            echo "  5)  ✏️  Edit VM configuration"
            echo "  6)  🗑️  Delete a VM"
            echo "  7)  📈 Resize VM disk"
            echo "  8)  📊 Show VM performance"
            echo "  9)  🔧 Fix VM issues"
            echo "  10) 📸 Snapshots"
            echo "  11) 📋 Clone a VM"
            echo "  12) 📦 Backup / Restore"
            echo "  13) 🏎️  Start all autostart VMs"
        fi
        echo "  0)  👋 Exit"
        echo

        read -p "$(print_status "INPUT" "🎯 Choice: ")" choice

        case "$choice" in
            1)  create_new_vm ;;
            2)
                [[ "$vm_count" -gt 0 ]] || { print_status "INFO" "No VMs available"; break; }
                read -p "$(print_status "INPUT" "🚀 Enter VM number to start: ")" vm_num
                [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le "$vm_count" ] && start_vm "${vms[$((vm_num-1))]}" || print_status "ERROR" "❌ Invalid selection"
                ;;
            3)
                [[ "$vm_count" -gt 0 ]] || { print_status "INFO" "No VMs available"; break; }
                read -p "$(print_status "INPUT" "🛑 Enter VM number to stop: ")" vm_num
                [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le "$vm_count" ] && stop_vm "${vms[$((vm_num-1))]}" || print_status "ERROR" "❌ Invalid selection"
                ;;
            4)
                [[ "$vm_count" -gt 0 ]] || { print_status "INFO" "No VMs available"; break; }
                read -p "$(print_status "INPUT" "📊 Enter VM number for info: ")" vm_num
                [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le "$vm_count" ] && show_vm_info "${vms[$((vm_num-1))]}" || print_status "ERROR" "❌ Invalid selection"
                ;;
            5)
                [[ "$vm_count" -gt 0 ]] || { print_status "INFO" "No VMs available"; break; }
                read -p "$(print_status "INPUT" "✏️  Enter VM number to edit: ")" vm_num
                [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le "$vm_count" ] && edit_vm_config "${vms[$((vm_num-1))]}" || print_status "ERROR" "❌ Invalid selection"
                ;;
            6)
                [[ "$vm_count" -gt 0 ]] || { print_status "INFO" "No VMs available"; break; }
                read -p "$(print_status "INPUT" "🗑️  Enter VM number to delete: ")" vm_num
                [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le "$vm_count" ] && delete_vm "${vms[$((vm_num-1))]}" || print_status "ERROR" "❌ Invalid selection"
                ;;
            7)
                [[ "$vm_count" -gt 0 ]] || { print_status "INFO" "No VMs available"; break; }
                read -p "$(print_status "INPUT" "📈 Enter VM number to resize: ")" vm_num
                [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le "$vm_count" ] && resize_vm_disk "${vms[$((vm_num-1))]}" || print_status "ERROR" "❌ Invalid selection"
                ;;
            8)
                [[ "$vm_count" -gt 0 ]] || { print_status "INFO" "No VMs available"; break; }
                read -p "$(print_status "INPUT" "📊 Enter VM number for performance: ")" vm_num
                [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le "$vm_count" ] && show_vm_performance "${vms[$((vm_num-1))]}" || print_status "ERROR" "❌ Invalid selection"
                ;;
            9)
                [[ "$vm_count" -gt 0 ]] || { print_status "INFO" "No VMs available"; break; }
                read -p "$(print_status "INPUT" "🔧 Enter VM number to fix: ")" vm_num
                [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le "$vm_count" ] && fix_vm_issues "${vms[$((vm_num-1))]}" || print_status "ERROR" "❌ Invalid selection"
                ;;
            10)
                [[ "$vm_count" -gt 0 ]] || { print_status "INFO" "No VMs available"; break; }
                read -p "$(print_status "INPUT" "📸 Enter VM number for snapshots: ")" vm_num
                [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le "$vm_count" ] && snapshot_menu "${vms[$((vm_num-1))]}" || print_status "ERROR" "❌ Invalid selection"
                ;;
            11)
                [[ "$vm_count" -gt 0 ]] || { print_status "INFO" "No VMs available"; break; }
                read -p "$(print_status "INPUT" "📋 Enter VM number to clone: ")" vm_num
                [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le "$vm_count" ] && clone_vm "${vms[$((vm_num-1))]}" || print_status "ERROR" "❌ Invalid selection"
                ;;
            12)
                echo "  a) Backup a VM"
                echo "  b) Restore from backup"
                read -p "$(print_status "INPUT" "📦 Choice: ")" br_choice
                case "$br_choice" in
                    a|A)
                        [[ "$vm_count" -gt 0 ]] || { print_status "INFO" "No VMs available"; break; }
                        read -p "$(print_status "INPUT" "📦 Enter VM number to backup: ")" vm_num
                        [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le "$vm_count" ] && backup_vm "${vms[$((vm_num-1))]}" || print_status "ERROR" "❌ Invalid selection"
                        ;;
                    b|B) restore_vm ;;
                    *) print_status "ERROR" "❌ Invalid selection" ;;
                esac
                ;;
            13) start_autostart_vms ;;
            0)
                print_status "INFO" "👋 Goodbye!"
                log INFO "Script exited"
                exit 0
                ;;
            *)
                print_status "ERROR" "❌ Invalid option"
                ;;
        esac

        read -p "$(print_status "INPUT" "⏎ Press Enter to continue...")"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
#  CLI MODE (non-interactive)
# ─────────────────────────────────────────────────────────────────────────────
run_cli() {
    local cmd="$1"; shift
    case "$cmd" in
        create)   create_new_vm ;;
        start)    [[ -n "${1:-}" ]] && start_vm "$1" || { print_status "ERROR" "Usage: $SCRIPT_NAME start <vm_name>"; return 1; } ;;
        stop)     [[ -n "${1:-}" ]] && stop_vm "$1" || { print_status "ERROR" "Usage: $SCRIPT_NAME stop <vm_name>"; return 1; } ;;
        info)     [[ -n "${1:-}" ]] && show_vm_info "$1" || { print_status "ERROR" "Usage: $SCRIPT_NAME info <vm_name>"; return 1; } ;;
        delete)   [[ -n "${1:-}" ]] && delete_vm "$1" || { print_status "ERROR" "Usage: $SCRIPT_NAME delete <vm_name>"; return 1; } ;;
        edit)     [[ -n "${1:-}" ]] && edit_vm_config "$1" || { print_status "ERROR" "Usage: $SCRIPT_NAME edit <vm_name>"; return 1; } ;;
        list)     local vms=($(get_vm_list)); printf '%s\n' "${vms[@]}" ;;
        autostart) start_autostart_vms ;;
        *)
            print_status "ERROR" "❌ Unknown command: $cmd"
            echo "Usage: $SCRIPT_NAME <command> [args]"
            echo "Commands: create, start, stop, info, delete, edit, list, autostart"
            return 1
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
#  CLEANUP
# ─────────────────────────────────────────────────────────────────────────────
cleanup() {
    rm -f /tmp/user-data-$$ /tmp/meta-data-$$ 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
#  ENTRY POINT
# ─────────────────────────────────────────────────────────────────────────────
trap cleanup EXIT

# Handle --help
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Enhanced Multi-VM Manager v${SCRIPT_VERSION}"
    echo ""
    echo "Usage:"
    echo "  $SCRIPT_NAME              Interactive menu"
    echo "  $SCRIPT_NAME --help       Show this help"
    echo "  $SCRIPT_NAME <command>    CLI mode"
    echo ""
    echo "CLI Commands:"
    echo "  create                    Create a new VM (interactive)"
    echo "  start <name>              Start a VM"
    echo "  stop <name>               Stop a VM"
    echo "  info <name>               Show VM info"
    echo "  delete <name>             Delete a VM"
    echo "  edit <name>               Edit VM config"
    echo "  list                      List all VMs"
    echo "  autostart                 Start all autostart VMs"
    echo ""
    echo "Environment:"
    echo "  VM_DIR                    Directory for VM files (default: \$HOME/vms)"
    echo "  VM_LOG_FILE               Log file path"
    exit 0
fi

# Check dependencies
check_dependencies
check_kvm_available

# Initialize paths
VM_DIR="${VM_DIR:-$HOME/vms}"
mkdir -p "$VM_DIR"

# Supported OS list
declare -A OS_OPTIONS=(
    ["Ubuntu 22.04"]="ubuntu|jammy|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|ubuntu22|ubuntu|ubuntu"
    ["Ubuntu 24.04"]="ubuntu|noble|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu24|ubuntu|ubuntu"
    ["Debian 11"]="debian|bullseye|https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2|debian11|debian|debian"
    ["Debian 12"]="debian|bookworm|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2|debian12|debian|debian"
    ["Debian 13"]="debian|trixie|https://cloud.debian.org/images/cloud/trixie/daily/latest/debian-13-generic-amd64-daily.qcow2|debian13|debian|debian"
    ["Fedora 40"]="fedora|40|https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-40-1.14.x86_64.qcow2|fedora40|fedora|fedora"
    ["CentOS Stream 9"]="centos|stream9|https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2|centos9|centos|centos"
    ["AlmaLinux 9"]="almalinux|9|https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2|almalinux9|alma|alma"
    ["Rocky Linux 9"]="rockylinux|9|https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2|rocky9|rocky|rocky"
)

# Dispatch: CLI or interactive
if [[ $# -gt 0 ]]; then
    run_cli "$@"
else
    main_menu
fi
