#!/usr/bin/env bash
# ==============================================================================
# Enhanced Multi-VM Manager — v5.2 (Ultimate Portability Edition)
# Built for: CoCalc, Cloud Shells, and restricted No-Root environments.
# ==============================================================================
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  GLOBAL CONSTANTS & ENV
# ─────────────────────────────────────────────────────────────────────────────
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="5.2"
readonly LOG_FILE="${VM_LOG_FILE:-$HOME/vms-manager.log}"
VM_DIR="${VM_DIR:-$HOME/vms}"
DATA_DIR="${DATA_DIR:-$HOME/.vms-data}"
REGISTRY_URL="${REGISTRY_URL:-docker.io}"

# Setup Rootless Environment Variables
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/podman-run-$(id -u)}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"

# ─────────────────────────────────────────────────────────────────────────────
#  DISPLAY & LOGGING
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

print_status() {
    local type="$1"; local msg="$2"
    case "$type" in
        INFO)    echo -e "\033[1;34m📋 [INFO]\033[0m $msg" ;;
        WARN)    echo -e "\033[1;33m⚠️  [WARN]\033[0m $msg" ;;
        ERROR)   echo -e "\033[1;31m❌ [ERROR]\033[0m $msg" ;;
        SUCCESS) echo -e "\033[1;32m✅ [SUCCESS]\033[0m $msg" ;;
        INPUT)   echo -e "\033[1;36m🎯 [INPUT]\033[0m $msg" ;;
        *)       echo "[$type] $msg" ;;
    esac
}

log() {
    local level="$1"; shift
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*" >> "$LOG_FILE" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
#  SYSTEM CONFIGURATION (ROOTLESS)
# ─────────────────────────────────────────────────────────────────────────────
init_rootless_configs() {
    mkdir -p "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME/containers" "$XDG_DATA_HOME/containers/storage"
    chmod 700 "$XDG_RUNTIME_DIR"

    # Check for driver mismatch and fix it
    if podman info 2>&1 | grep -q "overwritten by graph driver"; then
        print_status "WARN" "Driver mismatch detected. Cleaning old storage cache..."
        rm -rf "$XDG_DATA_HOME/containers/storage"
        mkdir -p "$XDG_DATA_HOME/containers/storage"
    fi

    # 1. Force VFS Storage (Crucial for Cloud/CoCalc)
    cat > "$XDG_CONFIG_HOME/containers/storage.conf" << EOF
[storage]
driver = "vfs"
runroot = "$XDG_RUNTIME_DIR"
graphroot = "$XDG_DATA_HOME/containers/storage"
[storage.options]
additionalimagestores = []
# Avoid UID/GID mapping errors in restricted environments
ignore_chown_errors = "true"
EOF

    # 2. Registries Config
    cat > "$XDG_CONFIG_HOME/containers/registries.conf" << EOF
unqualified-search-registries = ["$REGISTRY_URL", "quay.io", "ghcr.io"]
[[registry]]
location = "$REGISTRY_URL"
[[registry]]
location = "quay.io"
[[registry]]
location = "ghcr.io"
EOF
}

check_dependencies() {
    if ! command -v podman &>/dev/null; then
        print_status "ERROR" "Podman is not installed. Please install it first."
        exit 1
    fi
    
    # Try to initialize podman info to trigger any auto-configs
    if ! podman info &>/dev/null; then
        print_status "WARN" "Podman initialized with warnings, attempting to continue..."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  IMAGE & NETWORK DIAGNOSTICS
# ─────────────────────────────────────────────────────────────────────────────
diagnose_network() {
    local target="${REGISTRY_URL%%/*}"
    print_status "INFO" "🔍 Diagnosing connection to $target..."
    
    if ! host "$target" &>/dev/null && ! getent hosts "$target" &>/dev/null; then
        print_status "ERROR" "DNS Failure: Cannot resolve $target"
        return 1
    fi

    if ! curl -Is --connect-timeout 5 "https://$target" &>/dev/null; then
        print_status "ERROR" "Network Failure: Cannot reach https://$target (Port 443 blocked?)"
        return 1
    fi
    return 0
}

setup_vm_image() {
    local image="$1"
    
    if podman image inspect "$image" &>/dev/null; then
        print_status "SUCCESS" "Image $image is already available."
        return 0
    fi

    print_status "INFO" "📥 Attempting to download: $image"
    
    # Attempt 1: Standard Pull
    if podman pull "$image"; then return 0; fi

    # Attempt 2: Force Rootless mapping pull
    print_status "WARN" "Standard pull failed. Retrying with rootless mapping..."
    if podman pull --ignore-chown-errors "$image"; then return 0; fi

    # Attempt 3: TLS Verify False
    print_status "WARN" "Retrying without TLS verification..."
    if podman pull --tls-verify=false --ignore-chown-errors "$image"; then return 0; fi

    # Attempt 3: Diagnostic & Manual Advice
    diagnose_network || {
        print_status "ERROR" "❌ Internet access is BLOCKED in this environment."
        print_status "INFO" "💡 FIX: Download the image .tar manually on your PC, upload it here,"
        print_status "INFO" "   and use the 'Import' option in the menu."
    }
    return 1
}

import_image_manual() {
    print_status "INPUT" "Enter the full path to the .tar image file:"
    read -r tar_path
    if [ -f "$tar_path" ]; then
        print_status "INFO" "Importing $tar_path..."
        podman load -i "$tar_path" && print_status "SUCCESS" "Import successful!"
    else
        print_status "ERROR" "File not found: $tar_path"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  VM MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────
get_vm_list() {
    find "$VM_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | xargs -I{} basename {} | sort
}

is_vm_running() {
    [ "$(podman inspect --format '{{.State.Status}}' "vm-$1" 2>/dev/null)" == "running" ]
}

create_vm() {
    print_status "INPUT" "VM Name (no spaces):"
    read -r VM_NAME
    VM_NAME="${VM_NAME// /}"
    [ -z "$VM_NAME" ] && return 1

    print_status "INPUT" "Password for user 'root' and 'user':"
    read -rs PASSWORD; echo

    local image="${REGISTRY_URL}/library/ubuntu:22.04"
    setup_vm_image "$image" || return 1

    mkdir -p "$VM_DIR/$VM_NAME"
    cat > "$VM_DIR/$VM_NAME/config.sh" << EOF
VM_NAME="$VM_NAME"
PASSWORD="$PASSWORD"
IMAGE_NAME="$image"
SSH_PORT=$(shuf -i 2000-9000 -n 1)
EOF
    print_status "SUCCESS" "VM $VM_NAME configured."
}

start_vm() {
    local name="$1"
    local cfg="$VM_DIR/$name/config.sh"
    [ ! -f "$cfg" ] && return 1
    source "$cfg"

    podman rm -f "vm-$name" 2>/dev/null || true
    
    print_status "INFO" "Starting $name on port $SSH_PORT..."
    
    # Internal setup script
    local setup="
apt-get update -qq && apt-get install -y -qq openssh-server sudo 2>/dev/null || true;
mkdir -p /run/sshd;
ssh-keygen -A 2>/dev/null || true;
echo 'root:$PASSWORD' | chpasswd;
useradd -m -s /bin/bash user 2>/dev/null || true;
echo 'user:$PASSWORD' | chpasswd;
echo 'user ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers;
/usr/sbin/sshd -D
"

    # Use --userns=keep-id to avoid UID mapping issues in CoCalc
    podman run -d \
        --name "vm-$name" \
        -p "$SSH_PORT:22" \
        --userns=keep-id \
        --restart unless-stopped \
        "$IMAGE_NAME" \
        bash -c "$setup"
    
    sleep 2
    is_vm_running "$name" && print_status "SUCCESS" "VM $name is ONLINE." || print_status "ERROR" "Failed to start."
}

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN LOOP
# ─────────────────────────────────────────────────────────────────────────────
main() {
    mkdir -p "$VM_DIR"
    init_rootless_configs
    check_dependencies

    while true; do
        clear; echo "$BANNER"
        echo "--- Multi-VM Manager v$SCRIPT_VERSION ---"
        local vms=($(get_vm_list))
        for v in "${vms[@]}"; do
            echo "  [$(is_vm_running "$v" && echo "RUN" || echo "OFF")] $v"
        done
        echo "------------------------------------------"
        echo "  1) Create VM      2) Start VM"
        echo "  3) Stop VM        4) Delete VM"
        echo "  i) Import (.tar)  0) Exit"
        read -rp "Choice: " c
        case "$c" in
            1) create_vm ;;
            2) read -rp "Name: " n; start_vm "$n" ;;
            3) read -rp "Name: " n; podman stop "vm-$n" ;;
            4) read -rp "Name: " n; podman rm -f "vm-$n" 2>/dev/null; rm -rf "$VM_DIR/$n" ;;
            i) import_image_manual ;;
            0) exit 0 ;;
        esac
        read -rp "Press Enter..."
    done
}

main
