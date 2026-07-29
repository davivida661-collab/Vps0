#!/usr/bin/env bash
# ==============================================================================
# Enhanced Multi-VM Manager — v5.0 (Podman Edition)
# Lightweight VM manager using Podman — no daemon, no root needed.
#
# Changelog v5.0:
#   - Replaced kvmtool with Podman — runs as user, no daemon
#   - Auto-installs ALL dependencies (podman, openssh, debootstrap, etc.)
#   - Multi-OS support: Ubuntu, Debian, Alpine, CentOS, Fedora, Arch
#   - SSH access, snapshots, clone, backup, autostart
#   - Works on ANY Linux (no KVM required, no root required)
#   - All previous features preserved
# ==============================================================================
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  GLOBAL CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="5.0"
readonly LOG_FILE="${VM_LOG_FILE:-$HOME/vms-manager.log}"
VM_DIR="${VM_DIR:-$HOME/vms}"
DATA_DIR="${DATA_DIR:-$HOME/.vms-data}"

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
    echo "   Enhanced Multi-VM Manager  v${SCRIPT_VERSION} (Podman Edition)"
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
    case "$pm" in
        apt)
            sudo apt-get update -qq 2>/dev/null
            sudo apt-get install -y -qq "$@" 2>&1 | tail -3
            ;;
        dnf)
            sudo dnf install -y -q "$@" 2>&1 | tail -3
            ;;
        yum)
            sudo yum install -y -q "$@" 2>&1 | tail -3
            ;;
        pacman)
            sudo pacman -Sy --noconfirm "$@" 2>&1 | tail -3
            ;;
        apk)
            sudo apk add "$@" 2>&1 | tail -3
            ;;
        *)
            print_status "WARN" "⚠️  Unknown package manager — trying sudo install..."
            sudo apt-get install -y "$@" 2>&1 | tail -3 || true
            ;;
    esac
}

install_all_dependencies() {
    print_status "INFO" "🔧 Installing ALL dependencies automatically..."

    local pm
    pm=$(get_pkg_manager)

    # Update package lists
    case "$pm" in
        apt)    sudo apt-get update -qq 2>/dev/null ;;
        dnf)    sudo dnf makecache -q 2>/dev/null ;;
        yum)    sudo yum makecache -q 2>/dev/null ;;
        pacman) sudo pacman -Sy 2>/dev/null ;;
        apk)    sudo apk update 2>/dev/null ;;
    esac

    # ── Install Podman ──
    if ! command -v podman &>/dev/null; then
        print_status "INFO" "📦 Installing Podman..."
        case "$pm" in
            apt)
                # Try installing from distro repos first, then from obs
                sudo apt-get install -y -qq podman 2>/dev/null || true
                if ! command -v podman &>/dev/null; then
                    # Try Ubuntu's podman package
                    sudo apt-get install -y -qq podman rootlesskit 2>/dev/null || true
                fi
                if ! command -v podman &>/dev/null; then
                    # Fallback: install from OBS
                    print_status "INFO" "📦 Trying OBS repository..."
                    sudo apt-get install -y -qq software-properties-common 2>/dev/null || true
                    sudo apt-get install -y -qq podman 2>/dev/null || true
                fi
                ;;
            dnf)
                sudo dnf install -y -q podman 2>/dev/null || true
                ;;
            yum)
                sudo yum install -y -q podman 2>/dev/null || true
                ;;
            pacman)
                sudo pacman -S --noconfirm podman 2>/dev/null || true
                ;;
            apk)
                sudo apk add podman 2>/dev/null || true
                ;;
        esac
    fi

    if ! command -v podman &>/dev/null; then
        # Last resort: try snap
        print_status "INFO" "📦 Trying snap install..."
        sudo apt-get install -y -qq snapd 2>/dev/null || true
        sudo snap install podman 2>/dev/null || true
    fi

    if ! command -v podman &>/dev/null; then
        # Binary install from GitHub releases
        print_status "INFO" "📦 Installing Podman binary from GitHub..."
        local podman_url
        podman_url=$(curl -s https://api.github.com/repos/containers/podman/releases/latest 2>/dev/null | grep "browser_download_url.*linux_amd64" | head -1 | cut -d'"' -f4)
        if [[ -n "$podman_url" ]]; then
            curl -sL "$podman_url" -o /tmp/podman.tar.gz 2>/dev/null
            tar xzf /tmp/podman.tar.gz -C /tmp 2>/dev/null
            sudo cp /tmp/podman /usr/local/bin/ 2>/dev/null || 
            cp /tmp/podman "$HOME/.local/bin/" 2>/dev/null || true
            chmod +x "$HOME/.local/bin/podman" 2>/dev/null || true
            export PATH="$HOME/.local/bin:$PATH"
        fi
        rm -f /tmp/podman.tar.gz
    fi

    if ! command -v podman &>/dev/null; then
        print_status "ERROR" "❌ Failed to install Podman"
        print_status "INFO"  "💡 Try manually: sudo apt install podman"
        exit 1
    fi

    print_status "SUCCESS" "✅ Podman installed: $(podman --version 2>/dev/null | head -1)"

    # ── Install SSH client ──
    if ! command -v ssh &>/dev/null; then
        print_status "INFO" "📦 Installing OpenSSH client..."
        pkg_install openssh-client 2>/dev/null || true
    fi

    # ── Install other tools ──
    for tool in curl wget lsof openssl tar; do
        if ! command -v "$tool" &>/dev/null; then
            print_status "INFO" "📦 Installing $tool..."
            pkg_install "$tool" 2>/dev/null || true
        fi
    done

    # ── Start Podman machine if needed (macOS) ──
    if podman info &>/dev/null 2>&1; then
        print_status "SUCCESS" "✅ Podman is working"
    else
        print_status "INFO" "📦 Starting Podman machine..."
        podman machine init 2>/dev/null || true
        podman machine start 2>/dev/null || true
        sleep 3
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  PODMAN CHECK
# ─────────────────────────────────────────────────────────────────────────────
check_podman() {
    install_all_dependencies

    # Ensure registries are configured (fix for many minimal distros)
    if [ ! -f /etc/containers/registries.conf ] && [ ! -f "$HOME/.config/containers/registries.conf" ]; then
        print_status "INFO" "🔧 Configuring Podman registries..."
        mkdir -p "$HOME/.config/containers"
        cat > "$HOME/.config/containers/registries.conf" << EOF
unqualified-search-registries = ["docker.io", "quay.io"]

[[registry]]
location = "docker.io"

[[registry]]
location = "quay.io"
EOF
    fi

    # Verify podman works
    if ! podman info &>/dev/null 2>&1; then
        print_status "WARN" "⚠️  Podman not responding, trying to fix..."
        podman machine start 2>/dev/null || true
        sleep 3
        if ! podman info &>/dev/null 2>&1; then
            print_status "ERROR" "❌ Podman is not working"
            exit 1
        fi
    fi

    # Show host info
    local total_mem_mb
    total_mem_mb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 524288) / 1024 ))
    local host_cpus
    host_cpus=$(nproc 2>/dev/null || echo 2)
    print_status "INFO" "🐎 Podman ready | ${total_mem_mb}MB RAM | ${host_cpus} CPUs"
}

# ─────────────────────────────────────────────────────────────────────────────
#  VM CONFIGURATION HELPERS
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

get_vm_pid() {
    local vm_name="$1"
    local container_name="vm-${vm_name}"
    podman inspect --format '{{.State.Pid}}' "$container_name" 2>/dev/null || echo ""
}

REQUIRED_CONFIG_VARS=(
    VM_NAME HOSTNAME USERNAME PASSWORD
    IMAGE_NAME MEMORY CPUS SSH_PORT
)

load_vm_config() {
    local vm_name="$1"
    local config_file="$VM_DIR/$vm_name/config.sh"

    if [[ ! -f "$config_file" ]]; then
        print_status "ERROR" "❌ Config file not found: $config_file"
        return 1
    fi

    # shellcheck source=/dev/null
    source "$config_file"

    # Apply defaults
    AUTOSTART="${AUTOSTART:-false}"
    BACKGROUND_MODE="${BACKGROUND_MODE:-true}"
    MEMORY="${MEMORY:-512m}"
    CPUS="${CPUS:-2}"
    CREATED="${CREATED:-unknown}"
    DISK_SIZE="${DISK_SIZE:-2g}"
    OS_TYPE="${OS_TYPE:-ubuntu}"
    SSH_PORT="${SSH_PORT:-2222}"
    SSH_PASSWORD_ENABLED="${SSH_PASSWORD_ENABLED:-true}"
    SSH_USERNAME="${SSH_USERNAME:-user}"
    IMAGE_NAME="${IMAGE_NAME:-ubuntu:22.04}"

    # Validate required vars
    for var in "${REQUIRED_CONFIG_VARS[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            print_status "WARN" "⚠️  Missing config variable: $var"
        fi
    done
}

save_vm_config() {
    local vm_name="$1"
    local config_file="$VM_DIR/$vm_name/config.sh"

    mkdir -p "$VM_DIR/$vm_name"

    cat > "$config_file" << EOF
# VM Configuration — $vm_name
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
BACKGROUND_MODE=$BACKGROUND_MODE
CREATED="$CREATED"
SSH_PASSWORD_ENABLED=$SSH_PASSWORD_ENABLED
SSH_USERNAME="${SSH_USERNAME:-user}"
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
#  IMAGE MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────
setup_vm_image() {
    local image="$1"

    print_status "INFO" "📦 Checking/Downloading image: $image..."

    # Check if image exists locally
    if podman image inspect "$image" &>/dev/null; then
        print_status "INFO" "📦 Image already exists locally: $image"
        return 0
    fi

    # Try multiple image variants
    local image_variants=()
    case "${image,,}" in
        ubuntu*)
            image_variants=("docker.io/library/ubuntu:24.04" "docker.io/library/ubuntu:22.04" "docker.io/library/ubuntu:20.04" "docker.io/library/ubuntu:latest" "$image")
            ;;
        debian*)
            image_variants=("docker.io/library/debian:bookworm" "docker.io/library/debian:bullseye" "docker.io/library/debian:latest" "$image")
            ;;
        alpine*)
            image_variants=("docker.io/library/alpine:3.20" "docker.io/library/alpine:3.19" "docker.io/library/alpine:latest" "$image")
            ;;
        centos*)
            image_variants=("quay.io/centos/centos:stream9" "centos:7" "$image")
            ;;
        fedora*)
            image_variants=("fedora:latest" "fedora:40" "$image")
            ;;
        arch*)
            image_variants=("archlinux:latest" "$image")
            ;;
        rocky*|almalinux*)
            image_variants=("rockylinux:9-minimal" "rockylinux:8-minimal" "$image")
            ;;
        *)
            image_variants=("$image")
            ;;
    esac

    for variant in "${image_variants[@]}"; do
        print_status "INFO" "📥 Trying: $variant..."
        
        # Try with --tls-verify=false if standard pull fails (common in some restricted networks)
        local pull_output
        pull_output=$(podman pull "$variant" 2>&1)
        local pull_exit=$?
        
        if [ $pull_exit -ne 0 ]; then
            print_status "INFO" "🔄 Pull failed, retrying with --tls-verify=false..."
            pull_output=$(podman pull --tls-verify=false "$variant" 2>&1)
            pull_exit=$?
        fi

        if [ $pull_exit -eq 0 ]; then
            # Tag to requested name if different
            if [[ "$variant" != "$image" ]]; then
                podman tag "$variant" "$image" 2>/dev/null || true
            fi
            print_status "SUCCESS" "✅ Image ready: $variant"
            return 0
        fi
    done

    print_status "ERROR" "❌ Failed to pull any image variant"
    print_status "INFO"  "🔍 Last error from Podman:"
    echo "$pull_output" | sed 's/^/   /'
    echo
    print_status "INFO"  "💡 Possible causes:"
    print_status "INFO"  "   1. No internet connection or proxy issues"
    print_status "INFO"  "   2. Podman Hub rate limit (Docker Hub)"
    print_status "INFO"  "   3. DNS resolution failed"
    print_status "INFO"  "   4. Registries not configured in /etc/containers/registries.conf"
    echo
    print_status "INFO"  "💡 Try manually: podman pull docker.io/library/alpine:latest"
    return 1
}

get_default_image() {
    local os_type="$1"
    case "${os_type,,}" in
        ubuntu*)  echo "docker.io/library/ubuntu:22.04" ;;
        debian*)  echo "docker.io/library/debian:bookworm" ;;
        alpine*)  echo "docker.io/library/alpine:latest" ;;
        centos*)  echo "quay.io/centos/centos:stream9" ;;
        rocky*|almalinux*) echo "docker.io/rockylinux/rockylinux:9-minimal" ;;
        fedora*)  echo "docker.io/library/fedora:latest" ;;
        arch*)    echo "docker.io/library/archlinux:latest" ;;
        *)        echo "docker.io/library/ubuntu:22.04" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
#  SSH SETUP SCRIPT (injected into container)
# ─────────────────────────────────────────────────────────────────────────────
get_ssh_setup_script() {
    cat << 'SSHEOF'
#!/bin/bash
set -e

# Install SSH server if not present
if ! command -v sshd &>/dev/null; then
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq openssh-server sudo passwd 2>/dev/null || true
    elif command -v dnf &>/dev/null; then
        dnf install -y -q openssh-server sudo passwd 2>/dev/null || true
    elif command -v apk &>/dev/null; then
        apk add openssh openssh-server sudo shadow 2>/dev/null || true
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm openssh sudo 2>/dev/null || true
    fi
fi

# Generate SSH keys
mkdir -p /run/sshd /etc/ssh
ssh-keygen -A 2>/dev/null || true

# Configure SSH
echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
echo "Port 22" >> /etc/ssh/sshd_config

# Set root password
echo "root:$VM_PASS" | chpasswd 2>/dev/null || true

# Create user if specified
if [ -n "$VM_USER" ] && [ "$VM_USER" != "root" ]; then
    if ! id "$VM_USER" &>/dev/null; then
        useradd -m -s /bin/bash "$VM_USER" 2>/dev/null || true
    fi
    echo "$VM_USER:$VM_PASS" | chpasswd 2>/dev/null || true
    echo "$VM_USER ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers 2>/dev/null || true
    mkdir -p /home/"$VM_USER"
    chown "$VM_USER:$VM_USER" /home/"$VM_USER"
fi

# Set hostname
echo "$VM_HOSTNAME" > /etc/hostname 2>/dev/null || true

# Start SSH daemon
mkdir -p /run/sshd
/usr/sbin/sshd -D -e &
SSHEOF
}

# ─────────────────────────────────────────────────────────────────────────────
#  VM LIFECYCLE
# ─────────────────────────────────────────────────────────────────────────────
create_new_vm() {
    print_status "INFO" "🆕 Creating a new VM..."
    echo "────────────────────────────────────────────────"

    # VM name
    while true; do
        read -rp "$(print_status "INPUT" "📛 VM name: ")" VM_NAME
        VM_NAME="${VM_NAME// /}"
        if [[ -z "$VM_NAME" ]]; then
            print_status "ERROR" "❌ Name cannot be empty"
        elif ! validate_input "name" "$VM_NAME"; then
            continue
        elif [[ -d "$VM_DIR/$VM_NAME" ]]; then
            print_status "ERROR" "❌ VM with this name already exists"
        else
            break
        fi
    done

    # Hostname
    while true; do
        read -rp "$(print_status "INPUT" "🏠 Hostname (default: $VM_NAME): ")" HOSTNAME
        HOSTNAME="${HOSTNAME:-$VM_NAME}"
        if validate_input "name" "$HOSTNAME"; then
            break
        fi
    done

    # Username
    while true; do
        read -rp "$(print_status "INPUT" "👤 Username (default: user): ")" USERNAME
        USERNAME="${USERNAME:-user}"
        if validate_input "username" "$USERNAME"; then
            break
        fi
    done

    # Password
    while true; do
        read -rsp "$(print_status "INPUT" "🔑 Password: ")" PASSWORD
        echo
        if [[ -z "$PASSWORD" ]]; then
            print_status "ERROR" "❌ Password cannot be empty"
        else
            break
        fi
    done

    # OS Type
    while true; do
        read -rp "$(print_status "INPUT" "🐧 OS type (ubuntu/debian/alpine/centos/fedora/arch, default: ubuntu): ")" OS_TYPE
        OS_TYPE="${OS_TYPE:-ubuntu}"
        case "$OS_TYPE" in
            ubuntu|debian|alpine|centos|fedora|arch|rocky|almalinux) break ;;
            "") OS_TYPE="ubuntu"; break ;;
            *) print_status "ERROR" "❌ Supported: ubuntu, debian, alpine, centos, fedora, arch, rocky, almalinux" ;;
        esac
    done

    # RAM
    while true; do
        read -rp "$(print_status "INPUT" "🧠 RAM (e.g., 512m, 1g, 2g, default: 512m): ")" MEMORY
        MEMORY="${MEMORY:-512m}"
        break
    done

    # CPUs
    while true; do
        read -rp "$(print_status "INPUT" "⚡ CPUs (default: 2): ")" CPUS
        CPUS="${CPUS:-2}"
        if validate_input "number" "$CPUS" && [ "$CPUS" -ge 1 ]; then
            break
        fi
    done

    # SSH Port
    while true; do
        read -rp "$(print_status "INPUT" "🔌 SSH Port (default: auto): ")" SSH_PORT
        SSH_PORT="${SSH_PORT:-0}"
        if [ "$SSH_PORT" -eq 0 ] || validate_input "port" "$SSH_PORT"; then
            break
        fi
    done

    # Auto-assign port if needed
    if [ "$SSH_PORT" -eq 0 ]; then
        SSH_PORT=$(shuf -i 2222-65535 -n 1)
        print_status "INFO" "🔌 Auto-assigned SSH port: $SSH_PORT"
    fi

    # Disk size
    while true; do
        read -rp "$(print_status "INPUT" "💾 Disk size (e.g., 2g, 4g, default: 2g): ")" DISK_SIZE
        DISK_SIZE="${DISK_SIZE:-2g}"
        break
    done

    # Image
    IMAGE_NAME=$(get_default_image "$OS_TYPE")
    print_status "INFO" "📦 Image: $IMAGE_NAME"

    # Download image
    setup_vm_image "$IMAGE_NAME" || {
        print_status "ERROR" "❌ Failed to get image"
        return 1
    }

    # Save config
    CREATED="$(date)"
    AUTOSTART=false
    BACKGROUND_MODE=true
    SSH_PASSWORD_ENABLED=true
    save_vm_config "$VM_NAME"

    print_status "SUCCESS" "✅ VM '$VM_NAME' created!"
    log INFO "VM created: $VM_NAME"

    # Ask to start
    read -rp "$(print_status "INPUT" "🚀 Start VM now? (y/n, default: y): ")" start_now
    start_now="${start_now:-y}"
    if [[ "$start_now" =~ ^[Yy]$ ]]; then
        start_vm "$VM_NAME"
    fi
}

start_vm() {
    local vm_name="$1"
    load_vm_config "$vm_name" || return 1

    local container_name="vm-${vm_name}"

    if is_vm_running "$vm_name"; then
        print_status "INFO" "ℹ️  VM '$vm_name' is already running"
        return 0
    fi

    # Verify image
    if ! podman image inspect "$IMAGE_NAME" &>/dev/null; then
        setup_vm_image "$IMAGE_NAME" || return 1
    fi

    # Check disk space
    local avail_mb
    avail_mb=$(df -BM "$VM_DIR" 2>/dev/null | tail -1 | awk '{gsub("M",""); print $4}') || avail_mb=0
    if [ "${avail_mb:-0}" -lt 100 ]; then
        print_status "ERROR" "❌ Not enough disk space (${avail_mb:-0}MB available)"
        return 1
    fi

    # Remove old container if exists (stopped)
    podman rm -f "$container_name" 2>/dev/null || true

    # Create setup script
    local setup_script="$VM_DIR/$vm_name/setup-ssh.sh"
    mkdir -p "$VM_DIR/$vm_name"
    VM_PASS="$PASSWORD"
    VM_USER="$USERNAME"
    VM_HOSTNAME="$HOSTNAME"
    get_ssh_setup_script > "$setup_script"
    chmod +x "$setup_script"

    print_status "INFO" "🚀 Starting VM: $vm_name..."
    print_status "INFO" "📊 Config: ${MEMORY} RAM | ${CPUS} CPUs | SSH:$SSH_PORT"

    # Build podman run command
    local podman_cmd=(podman run
        -d
        --name "$container_name"
        --hostname "$HOSTNAME"
        -p "$SSH_PORT:22"
        --memory "$MEMORY"
        --cpus "$CPUS"
        --restart unless-stopped
        "$IMAGE_NAME"
    )

    # Run container (keep it alive with sleep or sshd)
    podman run 
        -d 
        --name "$container_name" 
        --hostname "$HOSTNAME" 
        -p "$SSH_PORT:22" 
        --memory "$MEMORY" 
        --cpus "$CPUS" 
        --restart unless-stopped 
        "$IMAGE_NAME" 
        bash -c "$setup_script" 2>&1 | tail -1 || true

    # Wait for container to start
    sleep 3

    if is_vm_running "$vm_name"; then
        print_status "SUCCESS" "✅ VM '$vm_name' started!"
        print_status "INFO" "📊 SSH: ssh -p $SSH_PORT $USERNAME@localhost"
        log INFO "VM started: $vm_name (SSH port: $SSH_PORT)"
    else
        print_status "WARN" "⚠️  VM may have failed to start"
        print_status "INFO"  "💡 Check logs: podman logs $container_name"
        podman logs "$container_name" 2>/dev/null | tail -5 || true
    fi
}

stop_vm() {
    local vm_name="$1"
    local container_name="vm-${vm_name}"

    if ! is_vm_running "$vm_name"; then
        # Check if container exists but stopped
        local state
        state=$(podman inspect --format '{{.State.Status}}' "$container_name" 2>/dev/null || echo "missing")
        if [[ "$state" == "missing" ]]; then
            print_status "WARN" "⚠️  VM '$vm_name' does not exist"
            return 0
        fi
        print_status "INFO" "ℹ️  VM '$vm_name' is not running"
        return 0
    fi

    print_status "INFO" "🛑 Stopping VM: $vm_name..."
    podman stop -t 10 "$container_name" 2>/dev/null || podman kill "$container_name" 2>/dev/null || true

    print_status "SUCCESS" "✅ VM '$vm_name' stopped"
    log INFO "VM stopped: $vm_name"
}

restart_vm() {
    local vm_name="$1"
    load_vm_config "$vm_name" || return 1
    stop_vm "$vm_name"
    sleep 2
    start_vm "$vm_name"
}

delete_vm() {
    local vm_name="$1"
    load_vm_config "$vm_name" 2>/dev/null || true
    local container_name="vm-${vm_name}"

    print_status "WARN" "⚠️  This will DELETE VM '$vm_name' and ALL its data!"
    read -rp "$(print_status "INPUT" "🗑️  Type the VM name to confirm: ")" confirm
    if [[ "$confirm" != "$vm_name" ]]; then
        print_status "ERROR" "❌ Confirmation failed"
        return 1
    fi

    # Stop and remove container
    podman rm -f "$container_name" 2>/dev/null || true

    # Remove VM directory
    if [[ -d "$VM_DIR/$vm_name" ]]; then
        rm -rf "$VM_DIR/$vm_name"
    fi

    # Remove snapshots
    if [[ -d "$VM_DIR/snapshots/$vm_name" ]]; then
        rm -rf "$VM_DIR/snapshots/$vm_name"
    fi

    print_status "SUCCESS" "✅ VM '$vm_name' deleted completely"
    log INFO "VM deleted: $vm_name"
}

# ─────────────────────────────────────────────────────────────────────────────
#  VM INFO & PERFORMANCE
# ─────────────────────────────────────────────────────────────────────────────
show_vm_info() {
    local vm_name="$1"
    load_vm_config "$vm_name" || return 1

    local status="💤 Stopped"
    is_vm_running "$vm_name" && status="🚀 Running"

    echo "═══════════════════════════════════════════════"
    echo "  VM: $VM_NAME"
    echo "  Status: $status"
    echo "───────────────────────────────────────────────"
    echo "  OS Type:    $OS_TYPE"
    echo "  Image:      $IMAGE_NAME"
    echo "  Hostname:   $HOSTNAME"
    echo "  Username:   $USERNAME"
    echo "  RAM:        $MEMORY"
    echo "  CPUs:       $CPUS"
    echo "  Disk:       $DISK_SIZE"
    echo "  SSH Port:   $SSH_PORT"
    echo "  Autostart:  $AUTOSTART"
    echo "  Created:    $CREATED"
    if is_vm_running "$vm_name"; then
        local container_name="vm-${vm_name}"
        echo "  Container:  $container_name"
        echo "  SSH:        ssh -p $SSH_PORT $USERNAME@localhost"
        echo "  PID:        $(get_vm_pid "$vm_name")"
    fi
    echo "═══════════════════════════════════════════════"
}

show_vm_performance() {
    local vm_name="$1"
    local container_name="vm-${vm_name}"

    if ! is_vm_running "$vm_name"; then
        print_status "WARN" "⚠️  VM '$vm_name' is not running"
        return 0
    fi

    echo "═══════════════════════════════════════════════"
    echo "  Performance: $vm_name"
    echo "───────────────────────────────────────────────"
    echo "  CPU: $(podman stats --no-stream --format '{{.CPUPerc}}' "$container_name" 2>/dev/null || echo 'N/A')"
    echo "  MEM: $(podman stats --no-stream --format '{{.MemUsage}}' "$container_name" 2>/dev/null || echo 'N/A')"
    echo "  NET: $(podman stats --no-stream --format '{{.NetInput}} / {{.NetOutput}}' "$container_name" 2>/dev/null || echo 'N/A')"
    echo "  PID: $(get_vm_pid "$vm_name")"
    echo "═══════════════════════════════════════════════"
}

# ─────────────────────────────────────────────────────────────────────────────
#  SSH INTO VM
# ─────────────────────────────────────────────────────────────────────────────
ssh_vm() {
    local vm_name="$1"
    load_vm_config "$vm_name" || return 1

    if ! is_vm_running "$vm_name"; then
        print_status "ERROR" "❌ VM '$vm_name' is not running"
        return 1
    fi

    print_status "INFO" "🖥️  Connecting to VM '$vm_name' via SSH..."
    print_status "INFO" "📊 ssh -p $SSH_PORT $USERNAME@localhost"

    # Try password auth
    if command -v sshpass &>/dev/null; then
        sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -p "$SSH_PORT" "${USERNAME}@localhost"
    else
        ssh -o StrictHostKeyChecking=no -p "$SSH_PORT" "${USERNAME}@localhost"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  EDIT VM CONFIG
# ─────────────────────────────────────────────────────────────────────────────
edit_vm_config() {
    local vm_name="$1"
    load_vm_config "$vm_name" || return 1

    if is_vm_running "$vm_name"; then
        print_status "WARN" "⚠️  VM is running. Stop it first for changes to take effect."
        read -rp "$(print_status "INPUT" "🔄 Stop VM to apply changes? (y/N): ")" stop_confirm
        if [[ "$stop_confirm" =~ ^[Yy]$ ]]; then
            stop_vm "$vm_name"
        fi
    fi

    print_status "INFO" "✏️  Editing VM: $vm_name"
    echo "  Leave blank to keep current value."
    echo

    read -rp "Hostname [${HOSTNAME}]: " input; HOSTNAME="${input:-$HOSTNAME}"
    read -rp "Username [${USERNAME}]: " input; USERNAME="${input:-$USERNAME}"
    read -rsp "Password [****]: " input; echo; PASSWORD="${input:-$PASSWORD}"
    read -rp "RAM [${MEMORY}]: " input; MEMORY="${input:-$MEMORY}"
    read -rp "CPUs [${CPUS}]: " input; CPUS="${input:-$CPUS}"
    read -rp "SSH Port [${SSH_PORT}]: " input; SSH_PORT="${input:-$SSH_PORT}"
    read -rp "Disk size [${DISK_SIZE}]: " input; DISK_SIZE="${input:-$DISK_SIZE}"
    read -rp "Autostart [${AUTOSTART}]: " input; AUTOSTART="${input:-$AUTOSTART}"

    save_vm_config "$vm_name"
    print_status "SUCCESS" "✅ Config saved for '$vm_name'"

    if is_vm_running "$vm_name"; then
        print_status "INFO" "ℹ️  Restart VM to apply changes"
    fi

    log INFO "VM config edited: $vm_name"
}

# ─────────────────────────────────────────────────────────────────────────────
#  RESIZE (change resource limits)
# ─────────────────────────────────────────────────────────────────────────────
resize_vm() {
    local vm_name="$1"
    load_vm_config "$vm_name" || return 1

    print_status "INFO" "📈 Resize resources for: $vm_name"
    echo "  Current: ${MEMORY} RAM | ${CPUS} CPUs | Disk: $DISK_SIZE"

    read -rp "$(print_status "INPUT" "🧠 New RAM (e.g., 1g, Enter=same): ")" new_mem
    if [[ -n "$new_mem" ]]; then
        MEMORY="$new_mem"
    fi

    read -rp "$(print_status "INPUT" "⚡ New CPUs (Enter=same): ")" new_cpus
    if [[ -n "$new_cpus" ]]; then
        validate_input "number" "$new_cpus" || return 1
        CPUS="$new_cpus"
    fi

    read -rp "$(print_status "INPUT" "💾 New disk size (e.g., 4g, Enter=same): ")" new_disk
    if [[ -n "$new_disk" ]]; then
        DISK_SIZE="$new_disk"
    fi

    save_vm_config "$vm_name"
    print_status "SUCCESS" "✅ Resources updated: ${MEMORY} RAM | ${CPUS} CPUs | Disk: $DISK_SIZE"
    print_status "INFO" "ℹ️  Restart VM to apply changes"
    log INFO "VM resized: $vm_name"
}

# ─────────────────────────────────────────────────────────────────────────────
#  FIX VM ISSUES
# ─────────────────────────────────────────────────────────────────────────────
fix_vm_issues() {
    local vm_name="$1"
    load_vm_config "$vm_name" || return 1

    print_status "INFO" "🔧 Checking VM '$vm_name' for issues..."

    local issues=0

    # Check 1: Podman works
    if ! podman info &>/dev/null 2>&1; then
        print_status "INFO" "🔧 Podman not working — reinstalling..."
        install_all_dependencies
        (( issues++ )) || true
    fi

    # Check 2: Image exists
    if ! podman image inspect "$IMAGE_NAME" &>/dev/null; then
        print_status "INFO" "🔧 Image missing — downloading..."
        setup_vm_image "$IMAGE_NAME" || true
        (( issues++ )) || true
    fi

    # Check 3: Orphan container
    local container_name="vm-${vm_name}"
    local state
    state=$(podman inspect --format '{{.State.Status}}' "$container_name" 2>/dev/null || echo "missing")
    if [[ "$state" == "exited" ]]; then
        print_status "INFO" "🔧 Stale container found — cleaning up..."
        podman rm "$container_name" 2>/dev/null || true
        (( issues++ )) || true
    fi

    # Check 4: SSH client
    if ! command -v ssh &>/dev/null; then
        print_status "INFO" "🔧 Installing SSH client..."
        pkg_install openssh-client 2>/dev/null || true
        (( issues++ )) || true
    fi

    # Check 5: SSH keys
    if ! is_vm_running "$vm_name"; then
        print_status "INFO" "🔧 VM is stopped — checking if it can start..."
        if ! podman image inspect "$IMAGE_NAME" &>/dev/null; then
            setup_vm_image "$IMAGE_NAME" || true
        fi
    fi

    if [ "$issues" -eq 0 ]; then
        print_status "SUCCESS" "✅ No issues found for '$vm_name'"
    else
        print_status "INFO" "🔧 Fixed $issues issue(s)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  CLONE VM
# ─────────────────────────────────────────────────────────────────────────────
clone_vm() {
    local vm_name="$1"
    load_vm_config "$vm_name" || return 1

    echo "  Cloning VM: $vm_name"
    read -rp "$(print_status "INPUT" "📋 New VM name: ")" clone_name
    if [[ -z "$clone_name" ]] || ! validate_input "name" "$clone_name" 2>/dev/null; then
        print_status "ERROR" "❌ Invalid name"
        return 1
    fi

    if [[ -d "$VM_DIR/$clone_name" ]]; then
        print_status "ERROR" "❌ VM '$clone_name' already exists"
        return 1
    fi

    # Find available SSH port
    local new_port
    new_port=$(shuf -i 2222-65535 -n 1)

    # Copy VM directory
    cp -r "$VM_DIR/$vm_name" "$VM_DIR/$clone_name"

    # Update config
    VM_NAME="$clone_name"
    HOSTNAME="$clone_name"
    SSH_PORT="$new_port"
    CREATED="$(date)"
    save_vm_config "$clone_name"

    # Commit container as new image if running
    local container_name="vm-${vm_name}"
    if is_vm_running "$vm_name"; then
        print_status "INFO" "📦 Committing current state as new image..."
        podman commit "$container_name" "vm-${clone_name}:latest" 2>/dev/null || true
        IMAGE_NAME="vm-${clone_name}:latest"
        save_vm_config "$clone_name"
    fi

    print_status "SUCCESS" "✅ VM cloned: $vm_name -> $clone_name (SSH: $new_port)"
    log INFO "VM cloned: $vm_name -> $clone_name"
}

# ─────────────────────────────────────────────────────────────────────────────
#  SNAPSHOT MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────
snapshot_menu() {
    local vm_name="$1"

    while true; do
        echo
        echo "  📸 Snapshot Menu: $vm_name"
        echo "  1) Create snapshot"
        echo "  2) List snapshots"
        echo "  3) Revert to snapshot"
        echo "  4) Delete snapshot"
        echo "  0) Back"
        read -rp "$(print_status "INPUT" "🎯 Choice: ")" snap_choice

        case "$snap_choice" in
            1) snapshot_create "$vm_name" ;;
            2) snapshot_list "$vm_name" ;;
            3) snapshot_revert "$vm_name" ;;
            4) snapshot_delete "$vm_name" ;;
            0) return 0 ;;
            *) print_status "ERROR" "❌ Invalid option" ;;
        esac
    done
}

snapshot_create() {
    local vm_name="$1"
    load_vm_config "$vm_name" || return 1

    read -rp "$(print_status "INPUT" "📸 Snapshot name: ")" snap_name
    if [[ -z "$snap_name" ]]; then
        print_status "ERROR" "❌ Name cannot be empty"
        return 1
    fi

    local snap_dir="$VM_DIR/snapshots/$vm_name"
    mkdir -p "$snap_dir"

    local container_name="vm-${vm_name}"
    if is_vm_running "$vm_name"; then
        # Commit running container as snapshot
        podman commit "$container_name" "snap-${vm_name}-${snap_name}:latest" 2>/dev/null || true
    fi

    # Save config as snapshot
    cp "$VM_DIR/$vm_name/config.sh" "$snap_dir/${snap_name}-config.sh"

    cat > "$snap_dir/${snap_name}.meta" << EOF
name=$snap_name
vm=$vm_name
created=$(date)
container_state=$(podman inspect --format '{{.State.Status}}' "$container_name" 2>/dev/null || echo "unknown")
EOF

    print_status "SUCCESS" "✅ Snapshot '$snap_name' created for '$vm_name'"
    log INFO "Snapshot created: $vm_name/$snap_name"
}

snapshot_list() {
    local vm_name="$1"
    local snap_dir="$VM_DIR/snapshots/$vm_name"

    echo "═══════════════════════════════════════════════"
    echo "  Snapshots for: $vm_name"
    echo "───────────────────────────────────────────────"

    if [[ ! -d "$snap_dir" ]] || [[ -z "$(ls "$snap_dir"/*.meta 2>/dev/null)" ]]; then
        echo "  No snapshots found."
    else
        for meta in "$snap_dir"/*.meta; do
            [[ -f "$meta" ]] || continue
            local sname screated
            sname=$(grep "^name=" "$meta" | cut -d= -f2)
            screated=$(grep "^created=" "$meta" | cut -d= -f2-)
            printf "  📸 %-20s Created: %sn" "$sname" "$screated"
        done
    fi
    echo "═══════════════════════════════════════════════"
}

snapshot_revert() {
    local vm_name="$1"
    local snap_dir="$VM_DIR/snapshots/$vm_name"
    local container_name="vm-${vm_name}"

    if [[ ! -d "$snap_dir" ]] || [[ -z "$(ls "$snap_dir"/*.meta 2>/dev/null)" ]]; then
        print_status "ERROR" "❌ No snapshots found for '$vm_name'"
        return 1
    fi

    echo "  Available snapshots:"
    local idx=0
    declare -a snap_names
    for meta in "$snap_dir"/*.meta; do
        local sname
        sname=$(grep "^name=" "$meta" | cut -d= -f2)
        snap_names+=("$sname")
        (( idx++ )) || true
        printf "  %d) %sn" "$idx" "$sname"
    done

    read -rp "$(print_status "INPUT" "🎯 Select snapshot number: ")" sel
    if [[ "$sel" -ge 1 ]] && [[ "$sel" -le "${#snap_names[@]}" ]]; then
        local target="${snap_names[$((sel-1))]}"

        print_status "WARN" "⚠️  This will replace the current VM state!"
        read -rp "$(print_status "INPUT" "🔄 Confirm revert to '$target'? (y/N): ")" rev_confirm
        if [[ ! "$rev_confirm" =~ ^[Yy]$ ]]; then
            return 0
        fi

        # Stop VM first
        if is_vm_running "$vm_name"; then
            podman stop "$container_name" 2>/dev/null || true
        fi

        # Remove old container
        podman rm -f "$container_name" 2>/dev/null || true

        # Try to restore from committed image
        local snap_image="snap-${vm_name}-${target}:latest"
        if podman image inspect "$snap_image" &>/dev/null; then
            # Restore config from snapshot
            cp "$snap_dir/${target}-config.sh" "$VM_DIR/$vm_name/config.sh" 2>/dev/null || true
            load_vm_config "$vm_name"

            # Recreate container from snapshot image
            VM_PASS="$PASSWORD"
            VM_USER="$USERNAME"
            VM_HOSTNAME="$HOSTNAME"
            local setup_script="$VM_DIR/$vm_name/setup-ssh.sh"
            get_ssh_setup_script > "$setup_script"
            chmod +x "$setup_script"

            podman run -d 
                --name "$container_name" 
                --hostname "$HOSTNAME" 
                -p "$SSH_PORT:22" 
                --memory "$MEMORY" 
                --cpus "$CPUS" 
                --restart unless-stopped 
                "$snap_image" 
                bash -c "$setup_script" 2>&1 | tail -1 || true

            sleep 3
            print_status "SUCCESS" "✅ Reverted to snapshot '$target'"
        else
            print_status "WARN" "⚠️  Snapshot image not found — restored config only"
            cp "$snap_dir/${target}-config.sh" "$VM_DIR/$vm_name/config.sh" 2>/dev/null || true
        fi

        log INFO "Snapshot reverted: $vm_name -> $target"
    else
        print_status "ERROR" "❌ Invalid selection"
    fi
}

snapshot_delete() {
    local vm_name="$1"
    local snap_dir="$VM_DIR/snapshots/$vm_name"

    if [[ ! -d "$snap_dir" ]] || [[ -z "$(ls "$snap_dir"/*.meta 2>/dev/null)" ]]; then
        print_status "ERROR" "❌ No snapshots found"
        return 1
    fi

    echo "  Available snapshots:"
    local idx=0
    declare -a snap_names
    for meta in "$snap_dir"/*.meta; do
        local sname
        sname=$(grep "^name=" "$meta" | cut -d= -f2)
        snap_names+=("$sname")
        (( idx++ )) || true
        printf "  %d) %sn" "$idx" "$sname"
    done

    read -rp "$(print_status "INPUT" "🎯 Select snapshot to delete: ")" sel
    if [[ "$sel" -ge 1 ]] && [[ "$sel" -le "${#snap_names[@]}" ]]; then
        local target="${snap_names[$((sel-1))]}"

        rm -f "$snap_dir/${target}-config.sh"
        rm -f "$snap_dir/${target}.meta"
        # Remove committed image
        podman rmi "snap-${vm_name}-${target}:latest" 2>/dev/null || true

        print_status "SUCCESS" "✅ Snapshot '$target' deleted"
        log INFO "Snapshot deleted: $vm_name/$target"
    else
        print_status "ERROR" "❌ Invalid selection"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  BACKUP / RESTORE
# ─────────────────────────────────────────────────────────────────────────────
backup_vm() {
    local vm_name="$1"
    load_vm_config "$vm_name" || return 1

    local backup_dir="$VM_DIR/backups"
    mkdir -p "$backup_dir"

    local backup_file="$backup_dir/${vm_name}-$(date '+%Y%m%d-%H%M%S').tar.gz"

    print_status "INFO" "📦 Backing up VM '$vm_name'..."

    # Stop VM for consistent backup
    if is_vm_running "$vm_name"; then
        print_status "INFO" "ℹ️  Stopping VM for consistent backup..."
        podman stop "vm-${vm_name}" 2>/dev/null || true
    fi

    # Commit container state
    local container_name="vm-${vm_name}"
    podman commit "$container_name" "backup-${vm_name}-latest" 2>/dev/null || true
    podman save -o "$backup_dir/${vm_name}-image.tar" "backup-${vm_name}-latest" 2>/dev/null || true

    # Create full backup tarball
    tar czf "$backup_file" -C "$VM_DIR" "$vm_name" 2>/dev/null

    # Add image to backup
    if [[ -f "$backup_dir/${vm_name}-image.tar" ]]; then
        tar rf "$backup_file" -C "$backup_dir" "${vm_name}-image.tar" 2>/dev/null || true
        rm -f "$backup_dir/${vm_name}-image.tar"
    fi

    local size
    size=$(du -h "$backup_file" 2>/dev/null | cut -f1)
    print_status "SUCCESS" "✅ Backup saved: $backup_file (${size})"
    log INFO "VM backed up: $vm_name -> $backup_file"

    # Restart VM if it was running
    start_vm "$vm_name" 2>/dev/null || true
}

restore_vm() {
    local backup_dir="$VM_DIR/backups"

    if [[ ! -d "$backup_dir" ]] || [[ -z "$(ls "$backup_dir"/*.tar.gz 2>/dev/null)" ]]; then
        print_status "ERROR" "❌ No backups found in $backup_dir"
        return 1
    fi

    echo "  Available backups:"
    local idx=0
    declare -a backup_files
    for bf in "$backup_dir"/*.tar.gz; do
        backup_files+=("$bf")
        (( idx++ )) || true
        local fname fsize
        fname=$(basename "$bf")
        fsize=$(du -h "$bf" | cut -f1)
        printf "  %d) %s (%s)n" "$idx" "$fname" "$fsize"
    done

    read -rp "$(print_status "INPUT" "🎯 Select backup: ")" sel
    if [[ "$sel" -ge 1 ]] && [[ "$sel" -le "${#backup_files[@]}" ]]; then
        local target="${backup_files[$((sel-1))]}"

        print_status "WARN" "⚠️  This will overwrite the VM!"
        read -rp "$(print_status "INPUT" "🔄 Confirm restore? (y/N): ")" restore_confirm
        if [[ ! "$restore_confirm" =~ ^[Yy]$ ]]; then
            return 0
        fi

        # Extract backup
        tar xzf "$target" -C "$VM_DIR" 2>/dev/null

        # Load image if exists
        if [[ -f "$VM_DIR/backups"/*-image.tar ]]; then
            podman load -i "$VM_DIR/backups"/*-image.tar 2>/dev/null || true
            rm -f "$VM_DIR/backups"/*-image.tar
        fi

        print_status "SUCCESS" "✅ VM restored from backup"
        log INFO "VM restored from backup"
    else
        print_status "ERROR" "❌ Invalid selection"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  AUTOSTART
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
    [[ $started -gt 0 ]] && print_status "SUCCESS" "✅ Started $started autostart VM(s)" || 
        print_status "INFO" "ℹ️  No autostart VMs configured"
}

# ─────────────────────────────────────────────────────────────────────────────
#  LIST ALL VMs (including podman native)
# ─────────────────────────────────────────────────────────────────────────────
list_all_vms() {
    echo "═══════════════════════════════════════════════"
    echo "  All VMs (managed)"
    echo "───────────────────────────────────────────────"

    local vms=($(get_vm_list))
    if [ ${#vms[@]} -eq 0 ]; then
        echo "  No VMs created yet."
    else
        for i in "${!vms[@]}"; do
            local status="💤"
            is_vm_running "${vms[$i]}" && status="🚀"
            printf "  %2d) %-20s %sn" $((i+1)) "${vms[$i]}" "$status"
        done
    fi

    echo
    echo "═══════════════════════════════════════════════"
    echo "  Podman containers:"
    echo "───────────────────────────────────────────────"
    podman ps -a --format "table {{.Names}}t{{.Status}}t{{.Ports}}" 2>/dev/null | grep -E "vm-|^NAMES" || echo "  (none)"
    echo "═══════════════════════════════════════════════"
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
                printf "  %2d) %-20s %sn" $((i+1)) "${vms[$i]}" "$status"
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
            echo "  7)  📈 Resize VM resources"
            echo "  8)  📊 Show VM performance"
            echo "  9)  🔧 Fix VM issues"
            echo "  10) 📸 Snapshots"
            echo "  11) 📋 Clone a VM"
            echo "  12) 📦 Backup / Restore"
            echo "  13) 🖥️  SSH into VM"
            echo "  14) 📋 List all VMs"
            echo "  15) 🏎️  Start all autostart VMs"
        fi
        echo "  0)  👋 Exit"
        echo

        read -rp "$(print_status "INPUT" "🎯 Choice: ")" choice

        case "$choice" in
            1)  create_new_vm ;;
            2)
                [[ "$vm_count" -gt 0 ]] || { print_status "INFO" "No VMs available"; continue; }
                read -rp "$(print_status "INPUT" "🚀 Enter VM number to start: ")" vm_num
                [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le "$vm_count" ] && start_vm "${vms[$((vm_num-1))]}" || print_status "ERROR" "❌ Invalid selection"
                ;;
            3)
                [[ "$vm_count" -gt 0 ]] || { print_status "INFO" "No VMs available"; continue; }
                read -rp "$(print_status "INPUT" "🛑 Enter VM number to stop: ")" vm_num
                [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le "$vm_count" ] && stop_vm "${vms[$((vm_num-1))]}" || print_status "ERROR" "❌ Invalid selection"
                ;;
            4)
                [[ "$vm_count" -gt 0 ]] || { print_status "INFO" "No VMs available"; continue; }
                read -rp "$(print_status "INPUT" "📊 Enter VM number for info: ")" vm_num
                [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le "$vm_count" ] && show_vm_info "${vms[$((vm_num-1))]}" || print_status "ERROR" "❌ Invalid selection"
                ;;
            5)
                [[ "$vm_count" -gt 0 ]] || { print_status "INFO" "No VMs available"; continue; }
                read -rp "$(print_status "INPUT" "✏️  Enter VM number to edit: ")" vm_num
                [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le "$vm_count" ] && edit_vm_config "${vms[$((vm_num-1))]}" || print_status "ERROR" "❌ Invalid selection"
                ;;
            6)
                [[ "$vm_count" -gt 0 ]] || { print_status "INFO" "No VMs available"; continue; }
                read -rp "$(print_status "INPUT" "🗑️  Enter VM number to delete: ")" vm_num
                [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le "$vm_count" ] && delete_vm "${vms[$((vm_num-1))]}" || print_status "ERROR" "❌ Invalid selection"
                ;;
            7)
                [[ "$vm_count" -gt 0 ]] || { print_status "INFO" "No VMs available"; continue; }
                read -rp "$(print_status "INPUT" "📈 Enter VM number to resize: ")" vm_num
                [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le "$vm_count" ] && resize_vm "${vms[$((vm_num-1))]}" || print_status "ERROR" "❌ Invalid selection"
                ;;
            8)
                [[ "$vm_count" -gt 0 ]] || { print_status "INFO" "No VMs available"; continue; }
                read -rp "$(print_status "INPUT" "📊 Enter VM number for performance: ")" vm_num
                [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le "$vm_count" ] && show_vm_performance "${vms[$((vm_num-1))]}" || print_status "ERROR" "❌ Invalid selection"
                ;;
            9)
                [[ "$vm_count" -gt 0 ]] || { print_status "INFO" "No VMs available"; continue; }
                read -rp "$(print_status "INPUT" "🔧 Enter VM number to fix: ")" vm_num
                [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le "$vm_count" ] && fix_vm_issues "${vms[$((vm_num-1))]}" || print_status "ERROR" "❌ Invalid selection"
                ;;
            10)
                [[ "$vm_count" -gt 0 ]] || { print_status "INFO" "No VMs available"; continue; }
                read -rp "$(print_status "INPUT" "📸 Enter VM number for snapshots: ")" vm_num
                [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le "$vm_count" ] && snapshot_menu "${vms[$((vm_num-1))]}" || print_status "ERROR" "❌ Invalid selection"
                ;;
            11)
                [[ "$vm_count" -gt 0 ]] || { print_status "INFO" "No VMs available"; continue; }
                read -rp "$(print_status "INPUT" "📋 Enter VM number to clone: ")" vm_num
                [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le "$vm_count" ] && clone_vm "${vms[$((vm_num-1))]}" || print_status "ERROR" "❌ Invalid selection"
                ;;
            12)
                echo "  a) Backup a VM"
                echo "  b) Restore from backup"
                read -rp "$(print_status "INPUT" "📦 Choice: ")" br_choice
                case "$br_choice" in
                    a|A)
                        [[ "$vm_count" -gt 0 ]] || { print_status "INFO" "No VMs available"; continue; }
                        read -rp "$(print_status "INPUT" "📦 Enter VM number to backup: ")" vm_num
                        [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le "$vm_count" ] && backup_vm "${vms[$((vm_num-1))]}" || print_status "ERROR" "❌ Invalid selection"
                        ;;
                    b|B) restore_vm ;;
                    *) print_status "ERROR" "❌ Invalid selection" ;;
                esac
                ;;
            13)
                [[ "$vm_count" -gt 0 ]] || { print_status "INFO" "No VMs available"; continue; }
                read -rp "$(print_status "INPUT" "🖥️  Enter VM number to SSH: ")" vm_num
                [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le "$vm_count" ] && ssh_vm "${vms[$((vm_num-1))]}" || print_status "ERROR" "❌ Invalid selection"
                ;;
            14) list_all_vms ;;
            15) start_autostart_vms ;;
            0)
                print_status "INFO" "👋 Goodbye!"
                log INFO "Script exited"
                exit 0
                ;;
            *)
                print_status "ERROR" "❌ Invalid option"
                ;;
        esac

        read -rp "$(print_status "INPUT" "⏎ Press Enter to continue...")"
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
        ssh)      [[ -n "${1:-}" ]] && ssh_vm "$1" || { print_status "ERROR" "Usage: $SCRIPT_NAME ssh <vm_name>"; return 1; } ;;
        info)     [[ -n "${1:-}" ]] && show_vm_info "$1" || { print_status "ERROR" "Usage: $SCRIPT_NAME info <vm_name>"; return 1; } ;;
        delete)   [[ -n "${1:-}" ]] && delete_vm "$1" || { print_status "ERROR" "Usage: $SCRIPT_NAME delete <vm_name>"; return 1; } ;;
        edit)     [[ -n "${1:-}" ]] && edit_vm_config "$1" || { print_status "ERROR" "Usage: $SCRIPT_NAME edit <vm_name>"; return 1; } ;;
        list)     local vms=($(get_vm_list)); printf '%sn' "${vms[@]}" ;;
        autostart) start_autostart_vms ;;
        *)
            print_status "ERROR" "❌ Unknown command: $cmd"
            echo "Usage: $SCRIPT_NAME <command> [args]"
            echo "Commands: create, start, stop, ssh, info, delete, edit, list, autostart"
            return 1
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
#  CLEANUP
# ─────────────────────────────────────────────────────────────────────────────
cleanup() {
    # Clean up stale snapshot images
    podman images --filter "reference=snap-*" --format "{{.ID}}" 2>/dev/null | while read -r id; do
        # Keep them — they're snapshots
        true
    done
}

# ─────────────────────────────────────────────────────────────────────────────
#  ENTRY POINT
# ─────────────────────────────────────────────────────────────────────────────
trap cleanup EXIT

# Ensure directories exist
mkdir -p "$VM_DIR"
mkdir -p "$DATA_DIR"

if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    echo "Enhanced Multi-VM Manager v${SCRIPT_VERSION} (Podman Edition)"
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
    echo "  ssh <name>                SSH into VM"
    echo "  info <name>               Show VM info"
    echo "  delete <name>             Delete a VM"
    echo "  edit <name>               Edit VM config"
    echo "  list                      List all VMs"
    echo "  autostart                 Start all autostart VMs"
    echo ""
    echo "Features:"
    echo "  - No root required (Podman runs as user)"
    echo "  - No daemon needed (Podman is daemonless)"
    echo "  - Auto-installs all dependencies"
    echo "  - Works on any Linux distribution"
    echo "  - Multi-OS: Ubuntu, Debian, Alpine, CentOS, Fedora, Arch"
    echo ""
    echo "Environment:"
    echo "  VM_DIR                    Directory for VM files (default: $HOME/vms)"
    echo "  DATA_DIR                  Directory for data (default: $HOME/.vms-data)"
    echo "  VM_LOG_FILE               Log file path"
    exit 0
fi

if [[ -n "${1:-}" ]]; then
    check_podman
    run_cli "$@"
else
    check_podman
    main_menu
fi
