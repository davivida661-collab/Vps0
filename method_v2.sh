#!/bin/bash
set -euo pipefail

# ==============================================================================
# Enhanced Multi-VM Manager (Pure QEMU Version) — v3.1
# Optimized for restricted environments (CoCalc / Rootless)
# ==============================================================================

# ─────────────────────────────────────────────────────────────────────────────
#  GLOBAL CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="3.1"
readonly VM_DIR="${VM_DIR:-$HOME/vms}"
readonly LOG_FILE="$HOME/qemu-manager.log"

# ─────────────────────────────────────────────────────────────────────────────
#  BANNER
# ─────────────────────────────────────────────────────────────────────────────
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
    echo "   Pure QEMU Manager v${SCRIPT_VERSION} | Rootless & CoCalc Optimized"
    echo "   $(date '+%Y-%m-%d %H:%M:%S')"
    echo
}

# ─────────────────────────────────────────────────────────────────────────────
#  DISPLAY HELPERS
# ─────────────────────────────────────────────────────────────────────────────
print_status() {
    local type="$1"
    local message="$2"
    case "$type" in
        INFO)    echo -e "\\033[1;34m📋 [INFO]\\033[0m $message" ;;
        WARN)    echo -e "\\033[1;33m⚠️  [WARN]\\033[0m $message" ;;
        ERROR)   echo -e "\\033[1;31m❌ [ERROR]\\033[0m $message" ;;
        SUCCESS) echo -e "\\033[1;32m✅ [SUCCESS]\\033[0m $message" ;;
        INPUT)   echo -e "\\033[1;36m🎯 [INPUT]\\033[0m $message" ;;
        *)       echo "[$type] $message" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
#  DIAGNOSTICS & SYSTEM CHECKS
# ─────────────────────────────────────────────────────────────────────────────
diagnose_network() {
    print_status "INFO" "🔍 Diagnosing connection to cloud-images.ubuntu.com..."
    
    # DNS Check
    if ! host cloud-images.ubuntu.com >/dev/null 2>&1; then
        print_status "ERROR" "🌐 DNS resolution failed. Internet might be blocked."
        return 1
    fi
    
    # HTTP Check (Port 443)
    if ! timeout 2 bash -c "</dev/tcp/cloud-images.ubuntu.com/443" 2>/dev/null; then
        print_status "ERROR" "🌐 Connection to cloud-images.ubuntu.com:443 timed out."
        return 1
    fi
    
    print_status "SUCCESS" "🌐 Internet connection seems OK."
    return 0
}

check_dependencies() {
    local deps=("qemu-system-x86_64" "wget" "qemu-img" "lsof")
    local missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then missing+=("$dep"); fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        print_status "ERROR" "🔧 Missing: ${missing[*]}"
        print_status "INFO" "💡 Try: apt install qemu-system-x86 wget lsof cloud-image-utils"
        exit 1
    fi
}

check_host_resources() {
    local need_mem="$1"
    local free_mem
    free_mem=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    free_mem=$((free_mem / 1024)) # to MB
    
    if [ "$need_mem" -gt "$free_mem" ]; then
        print_status "WARN" "⚠️  Low RAM! Need ${need_mem}MB, only ${free_mem}MB available."
        read -p "$(print_status "INPUT" "Continue anyway? (y/N): ")" confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || return 1
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
#  VM CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
get_vm_list() {
    find "$VM_DIR" -maxdepth 1 -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort
}

load_vm_config() {
    local vm_name="$1"
    local config_file="$VM_DIR/$vm_name.conf"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
        return 0
    fi
    return 1
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
    print_status "SUCCESS" "💾 Config saved to $config_file"
}

# ─────────────────────────────────────────────────────────────────────────────
#  IMAGE MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────
import_manual_image() {
    print_status "INFO" "📦 Manual Image Import"
    read -p "$(print_status "INPUT" "Enter path to .img or .qcow2 file: ")" src_path
    if [[ ! -f "$src_path" ]]; then
        print_status "ERROR" "File not found: $src_path"
        return 1
    fi
    
    read -p "$(print_status "INPUT" "Enter a name for this VM: ")" VM_NAME
    VM_DIR="${VM_DIR:-$HOME/vms}"
    mkdir -p "$VM_DIR"
    
    IMG_FILE="$VM_DIR/$VM_NAME.img"
    cp "$src_path" "$IMG_FILE"
    
    # Default config for imported image
    OS_TYPE="Imported"
    CODENAME="manual"
    IMG_URL="none"
    HOSTNAME="$VM_NAME"
    USERNAME="admin"
    PASSWORD="password123"
    DISK_SIZE="20G"
    MEMORY="2048"
    CPUS="2"
    SSH_PORT="2222"
    GUI_MODE=false
    PORT_FORWARDS=""
    SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"
    CREATED="$(date)"
    
    save_vm_config
    print_status "SUCCESS" "✅ Image imported as '$VM_NAME'. Please edit config if needed."
}

setup_vm_image() {
    print_status "INFO" "📥 Preparing image for $VM_NAME..."
    mkdir -p "$VM_DIR"
    
    if [[ -f "$IMG_FILE" ]]; then
        print_status "INFO" "✅ Image already exists."
    else
        if [[ "$IMG_URL" == "none" ]]; then
            print_status "ERROR" "No download URL. Please import image manually."
            return 1
        fi
        
        print_status "INFO" "🌐 Downloading from $IMG_URL..."
        if ! wget -q --show-progress "$IMG_URL" -O "$IMG_FILE.tmp"; then
            print_status "ERROR" "❌ Download failed."
            diagnose_network
            rm -f "$IMG_FILE.tmp"
            return 1
        fi
        mv "$IMG_FILE.tmp" "$IMG_FILE"
    fi
    
    # Resize
    qemu-img resize "$IMG_FILE" "$DISK_SIZE" &>/dev/null || true
    
    # Cloud-init
    local pass_hash
    pass_hash=$(openssl passwd -6 "$PASSWORD" | tr -d '\n')
    
    cat > user-data <<EOF
#cloud-config
hostname: $HOSTNAME
ssh_pwauth: true
users:
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    passwd: $pass_hash
EOF
    echo "instance-id: iid-$VM_NAME" > meta-data
    
    if command -v cloud-localds &>/dev/null; then
        cloud-localds "$SEED_FILE" user-data meta-data
    else
        # Fallback to genisoimage
        genisoimage -output "$SEED_FILE" -volid cidata -joliet -rock user-data meta-data &>/dev/null
    fi
    rm -f user-data meta-data
}

# ─────────────────────────────────────────────────────────────────────────────
#  VM LIFECYCLE
# ─────────────────────────────────────────────────────────────────────────────
is_vm_running() {
    pgrep -f "qemu-system.*$1" >/dev/null
}

start_vm() {
    local vm_name="$1"
    load_vm_config "$vm_name" || return 1
    
    if is_vm_running "$vm_name"; then
        print_status "WARN" "VM $vm_name is already running."
        return 1
    fi
    
    check_host_resources "$MEMORY" || return 1
    
    # Build Command
    local qemu_cmd=(
        qemu-system-x86_64
        -m "$MEMORY"
        -smp "$CPUS"
        -cpu qemu64
        -machine type=pc,accel=tcg
        -drive "file=$IMG_FILE,format=qcow2,if=virtio"
        -drive "file=$SEED_FILE,format=raw,if=virtio"
        -netdev "user,id=n0,hostfwd=tcp::$SSH_PORT-:22"
        -device virtio-net-pci,netdev=n0
        -nographic
        -serial mon:stdio
    )
    
    # Add port forwards
    if [[ -n "$PORT_FORWARDS" ]]; then
        IFS=',' read -ra fwds <<< "$PORT_FORWARDS"
        local i=1
        for fwd in "${fwds[@]}"; do
            IFS=':' read -r hp gp <<< "$fwd"
            qemu_cmd+=(-netdev "user,id=n$i,hostfwd=tcp::$hp-:$gp" -device virtio-net-pci,netdev=n$i)
            ((i++))
        done
    fi

    print_status "INFO" "🚀 Starting $vm_name (Software Emulation)..."
    print_status "INFO" "🔌 SSH: ssh -p $SSH_PORT $USERNAME@localhost"
    print_status "INFO" "🛑 Press Ctrl+A then X to exit QEMU."
    
    # Start in background or foreground?
    # Since we are in a terminal script, foreground is better for feedback
    "${qemu_cmd[@]}"
}

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN INTERFACE
# ─────────────────────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        display_header
        local vms=($(get_vm_list))
        
        if [ ${#vms[@]} -gt 0 ]; then
            print_status "INFO" "VMs Found:"
            for i in "${!vms[@]}"; do
                local status="💤"
                is_vm_running "${vms[$i]}" && status="🚀"
                printf "  %d) %-15s %s\n" $((i+1)) "${vms[$i]}" "$status"
            done
            echo
        fi
        
        echo "1) 🆕 Create VM"
        echo "2) 🚀 Start VM"
        echo "3) 🛑 Stop VM (Kill)"
        echo "4) 🗑️  Delete VM"
        echo "5) 📦 Import External Image (.img/.qcow2)"
        echo "0) 👋 Exit"
        echo
        read -p "$(print_status "INPUT" "Choice: ")" choice
        
        case "$choice" in
            1) create_new_vm ;;
            2) 
                read -p "VM Number: " num
                start_vm "${vms[$((num-1))]}" ;;
            3)
                read -p "VM Number: " num
                pkill -f "qemu-system.*${vms[$((num-1))]}"
                print_status "SUCCESS" "Stopped." ;;
            4)
                read -p "VM Number: " num
                local name="${vms[$((num-1))]}"
                rm -f "$VM_DIR/$name"*
                print_status "SUCCESS" "Deleted." ;;
            5) import_manual_image ;;
            0) exit 0 ;;
        esac
        read -p "Press Enter..."
    done
}

# Supported OS
declare -A OS_OPTIONS=(
    ["Ubuntu 22.04"]="ubuntu|jammy|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|u22|ubuntu|ubuntu"
    ["Debian 12"]="debian|bookworm|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2|d12|debian|debian"
)

check_dependencies
main_menu
