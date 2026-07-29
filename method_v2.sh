#!/usr/bin/env bash
# ==============================================================================
# Enhanced Multi-VM Manager — v5.1 (Podman Rootless Edition)
# Optimized for restricted environments (CoCalc, Cloud, No-Root)
# ==============================================================================
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  GLOBAL CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="5.1"
readonly LOG_FILE="${VM_LOG_FILE:-$HOME/vms-manager.log}"
VM_DIR="${VM_DIR:-$HOME/vms}"
DATA_DIR="${DATA_DIR:-$HOME/.vms-data}"
# Mude o registro aqui (ex: quay.io, ghcr.io, etc.)
REGISTRY_URL="${REGISTRY_URL:-docker.io}"

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
    echo "   Enhanced Multi-VM Manager  v${SCRIPT_VERSION} (Podman Rootless)"
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
        *)
            print_status "ERROR" "❌ Unknown validation type: $type"
            return 1
            ;;
    esac
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
#  AUTO-INSTALL ALL DEPENDENCIES
# ─────────────────────────────────────────────────────────────────────────────
get_pkg_manager() {
    if command -v apt-get &>/dev/null; then echo "apt"; return; fi
    if command -v dnf &>/dev/null; then echo "dnf"; return; fi
    if command -v yum &>/dev/null; then echo "yum"; return; fi
    if command -v pacman &>/dev/null; then echo "pacman"; return; fi
    if command -v apk &>/dev/null; then echo "apk"; return; fi
    echo "unknown"
}

pkg_install() {
    local pm
    pm=$(get_pkg_manager)
    # Skip if not root and no sudo
    if [ "$USER" != "root" ] && ! command -v sudo &>/dev/null; then
        return 0
    fi
    case "$pm" in
        apt)
            sudo apt-get update -qq 2>/dev/null || true
            sudo apt-get install -y -qq "$@" 2>&1 | tail -3 || true
            ;;
        dnf|yum)
            sudo $pm install -y -q "$@" 2>&1 | tail -3 || true
            ;;
        pacman)
            sudo pacman -Sy --noconfirm "$@" 2>&1 | tail -3 || true
            ;;
        apk)
            sudo apk add "$@" 2>&1 | tail -3 || true
            ;;
    esac
}

install_all_dependencies() {
    # If in CoCalc or similar, we likely can't install system packages
    if [ -d "/home/user" ] && [ "$USER" != "root" ]; then
        return 0
    fi

    print_status "INFO" "🔧 Checking dependencies..."
    for tool in curl wget lsof openssl tar; do
        if ! command -v "$tool" &>/dev/null; then
            print_status "INFO" "📦 Installing $tool..."
            pkg_install "$tool"
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
#  PODMAN CHECK (ROOTLESS OPTIMIZED)
# ─────────────────────────────────────────────────────────────────────────────
check_podman() {
    # 1. Setup Environment for Rootless
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/podman-run-$(id -u)}"
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"

    # 2. Configure Local Storage and Registries
    mkdir -p "$HOME/.config/containers"
    
    # Storage: Force VFS for maximum compatibility in Cloud/CoCalc
    if [ ! -f "$HOME/.config/containers/storage.conf" ]; then
        print_status "INFO" "🔧 Configuring rootless storage (vfs)..."
        cat > "$HOME/.config/containers/storage.conf" << EOF
[storage]
driver = "vfs"
runroot = "$XDG_RUNTIME_DIR"
graphroot = "$HOME/.local/share/containers/storage"
EOF
    fi

    # Registries: Ensure search works without root
    if [ ! -f "$HOME/.config/containers/registries.conf" ]; then
        print_status "INFO" "🔧 Configuring rootless registries..."
        cat > "$HOME/.config/containers/registries.conf" << EOF
unqualified-search-registries = ["${REGISTRY_URL}", "quay.io"]
[[registry]]
location = "${REGISTRY_URL}"
[[registry]]
location = "quay.io"
EOF
    fi

    install_all_dependencies

    # 3. Verify Podman
    if ! command -v podman &>/dev/null; then
        print_status "ERROR" "❌ Podman not found. Please install it or ask your admin."
        exit 1
    fi

    if ! podman info &>/dev/null 2>&1; then
        print_status "WARN" "⚠️  Podman is present but not responding. Trying to fix..."
        # Last ditch effort: clear stale runroot
        rm -rf "$XDG_RUNTIME_DIR/*" 2>/dev/null || true
        if ! podman info &>/dev/null 2>&1; then
            print_status "ERROR" "❌ Podman failed to initialize in rootless mode."
            podman info 2>&1 | head -n 5 || true
            exit 1
        fi
    fi

    local total_mem_mb
    total_mem_mb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 524288) / 1024 ))
    print_status "SUCCESS" "🐎 Podman Rootless Ready | ${total_mem_mb}MB RAM"
}

# ─────────────────────────────────────────────────────────────────────────────
#  VM HELPERS
# ─────────────────────────────────────────────────────────────────────────────
get_vm_list() {
    find "$VM_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | while read -r dir; do
        if [[ -f "$dir/config.sh" ]]; then
            basename "$dir"
        fi
    done | sort
}

is_vm_running() {
    local vm_name="$1"
    local container_name="vm-${vm_name}"
    local state
    state=$(podman inspect --format '{{.State.Status}}' "$container_name" 2>/dev/null || echo "")
    [[ "$state" == "running" ]]
}

load_vm_config() {
    local vm_name="$1"
    local config_file="$VM_DIR/$vm_name/config.sh"
    if [[ ! -f "$config_file" ]]; then return 1; fi
    source "$config_file"
    # Defaults
    AUTOSTART="${AUTOSTART:-false}"
    MEMORY="${MEMORY:-512m}"
    CPUS="${CPUS:-2}"
    SSH_PORT="${SSH_PORT:-2222}"
    IMAGE_NAME="${IMAGE_NAME:-docker.io/library/ubuntu:22.04}"
}

save_vm_config() {
    local vm_name="$1"
    local config_file="$VM_DIR/$vm_name/config.sh"
    mkdir -p "$VM_DIR/$vm_name"
    cat > "$config_file" << EOF
VM_NAME="$VM_NAME"
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
PASSWORD="$PASSWORD"
OS_TYPE="$OS_TYPE"
IMAGE_NAME="$IMAGE_NAME"
SSH_PORT=$SSH_PORT
MEMORY="$MEMORY"
CPUS=$CPUS
DISK_SIZE="$DISK_SIZE"
AUTOSTART=$AUTOSTART
CREATED="$CREATED"
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
#  IMAGE MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────
setup_vm_image() {
    local image="$1"
    print_status "INFO" "📦 Checking image: $image..."
    
    if podman image inspect "$image" &>/dev/null; then
        return 0
    fi

    print_status "INFO" "🔍 Diagnosing network..."
    local net_error=0
    
    # DNS Test
    if ! host "${REGISTRY_URL%%/*}" &>/dev/null && ! getent hosts "${REGISTRY_URL%%/*}" &>/dev/null; then
        print_status "ERROR" "❌ DNS Failure: Cannot resolve ${REGISTRY_URL%%/*}"
        net_error=1
    fi
    
    # HTTP Test
    if ! curl -Is --connect-timeout 5 "https://${REGISTRY_URL%%/*}" >/dev/null 2>&1; then
        print_status "ERROR" "❌ Connection Failure: Cannot reach https://${REGISTRY_URL%%/*}"
        net_error=1
    fi

    if [ $net_error -eq 1 ]; then
        print_status "WARN" "⚠️  Your environment (CoCalc) might have restricted internet access."
        print_status "INFO" "💡 Alternative: Download the image manually as a .tar file and use the Import option."
        return 1
    fi

    print_status "INFO" "📥 Downloading $image..."
    local pull_out
    pull_out=$(podman pull "$image" 2>&1) || {
        print_status "INFO" "🔄 Pull failed, retrying with --tls-verify=false..."
        pull_out=$(podman pull --tls-verify=false "$image" 2>&1) || {
            print_status "ERROR" "❌ Podman Pull Error:"
            echo "$pull_out" | sed 's/^/   /'
            return 1
        }
    }
    return 0
}

import_image_manual() {
    print_status "INFO" "📥 Manual Image Import..."
    read -rp "$(print_status "INPUT" "📄 Path to image .tar file: ")" tar_path
    if [ ! -f "$tar_path" ]; then
        print_status "ERROR" "❌ File not found: $tar_path"
        return 1
    fi
    print_status "INFO" "📦 Loading image into Podman..."
    podman load -i "$tar_path" && print_status "SUCCESS" "✅ Image imported!" || print_status "ERROR" "❌ Import failed."
}

# ─────────────────────────────────────────────────────────────────────────────
#  LIFECYCLE
# ─────────────────────────────────────────────────────────────────────────────
get_ssh_setup_script() {
    cat << SSHEOF
#!/bin/bash
set -e
if ! command -v sshd &>/dev/null; then
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq openssh-server sudo passwd 2>/dev/null || true
    elif command -v apk &>/dev/null; then
        apk add openssh openssh-server sudo shadow 2>/dev/null || true
    fi
fi
mkdir -p /run/sshd /etc/ssh
ssh-keygen -A 2>/dev/null || true
echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
echo "root:$VM_PASS" | chpasswd 2>/dev/null || true
if [ -n "$VM_USER" ] && [ "$VM_USER" != "root" ]; then
    id "$VM_USER" &>/dev/null || useradd -m -s /bin/bash "$VM_USER" 2>/dev/null || true
    echo "$VM_USER:$VM_PASS" | chpasswd 2>/dev/null || true
    echo "$VM_USER ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers 2>/dev/null || true
fi
/usr/sbin/sshd -D -e
SSHEOF
}

create_new_vm() {
    print_status "INFO" "🆕 Creating a new VM..."
    read -rp "$(print_status "INPUT" "📛 VM name: ")" VM_NAME
    VM_NAME="${VM_NAME// /}"
    [ -z "$VM_NAME" ] && return 1
    
    read -rp "$(print_status "INPUT" "👤 Username (default: user): ")" USERNAME
    USERNAME="${USERNAME:-user}"
    
    read -rsp "$(print_status "INPUT" "🔑 Password: ")" PASSWORD; echo
    
    OS_TYPE="ubuntu"
    IMAGE_NAME="${REGISTRY_URL}/library/ubuntu:22.04"
    MEMORY="512m"
    CPUS="1"
    DISK_SIZE="2g"
    SSH_PORT=$(shuf -i 2222-9999 -n 1)
    HOSTNAME="$VM_NAME"
    CREATED="$(date)"
    AUTOSTART=false

    setup_vm_image "$IMAGE_NAME" || return 1
    save_vm_config "$VM_NAME"
    print_status "SUCCESS" "✅ VM '$VM_NAME' created!"
}

start_vm() {
    local vm_name="$1"
    load_vm_config "$vm_name" || return 1
    local container_name="vm-${vm_name}"

    if is_vm_running "$vm_name"; then
        print_status "INFO" "ℹ️  VM '$vm_name' already running"
        return 0
    fi

    podman rm -f "$container_name" 2>/dev/null || true
    
    local setup_script="$VM_DIR/$vm_name/setup.sh"
    VM_PASS="$PASSWORD" VM_USER="$USERNAME" get_ssh_setup_script > "$setup_script"
    chmod +x "$setup_script"

    print_status "INFO" "🚀 Starting VM: $vm_name (SSH Port: $SSH_PORT)..."
    podman run -d \
        --name "$container_name" \
        --hostname "$HOSTNAME" \
        -p "$SSH_PORT:22" \
        --memory "$MEMORY" \
        --restart unless-stopped \
        "$IMAGE_NAME" \
        bash -c "$(cat "$setup_script")" 2>&1 | tail -1 || true
    
    sleep 3
    is_vm_running "$vm_name" && print_status "SUCCESS" "✅ Started!" || print_status "ERROR" "❌ Failed to start"
}

stop_vm() {
    local vm_name="$1"
    print_status "INFO" "🛑 Stopping VM: $vm_name..."
    podman stop -t 5 "vm-${vm_name}" 2>/dev/null || podman kill "vm-${vm_name}" 2>/dev/null || true
}

delete_vm() {
    local vm_name="$1"
    print_status "WARN" "⚠️  Deleting VM '$vm_name'..."
    podman rm -f "vm-${vm_name}" 2>/dev/null || true
    rm -rf "$VM_DIR/$vm_name"
    print_status "SUCCESS" "✅ Deleted"
}

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN MENU
# ─────────────────────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        display_header
        local vms=($(get_vm_list))
        echo "📋 Menu:"
        echo "  1) 🆕 Create VM"
        echo "  i) 📥 Import Image (.tar)"
        [ ${#vms[@]} -gt 0 ] && {
            echo "  2) 🚀 Start VM"
            echo "  3) 🛑 Stop VM"
            echo "  4) 🗑️  Delete VM"
            echo "  5) 🖥️  List VMs"
        }
        echo "  0) 👋 Exit"
        read -rp "🎯 Choice: " choice
        case "$choice" in
            1) create_new_vm ;;
            i|I) import_image_manual ;;
            2) read -rp "Name: " n; start_vm "$n" ;;
            3) read -rp "Name: " n; stop_vm "$n" ;;
            4) read -rp "Name: " n; delete_vm "$n" ;;
            5) for v in $(get_vm_list); do echo "- $v ($(is_vm_running "$v" && echo "Running" || echo "Stopped"))"; done ;;
            0) exit 0 ;;
        esac
        read -rp "Press Enter..."
    done
}

# ─────────────────────────────────────────────────────────────────────────────
#  ENTRY
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "$VM_DIR" "$DATA_DIR"
check_podman
main_menu
