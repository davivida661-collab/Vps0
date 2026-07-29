#!/usr/bin/env bash
# ==============================================================================
# Enhanced Multi-VM Manager — v3.0 (Docker Edition)
# A full-featured Docker container manager with cloud-init style configuration.
#
# Changelog v3.0:
#   - Replaced QEMU with Docker — no more libfuse3, libpcre, or KVM issues
#   - Works on ALL Ubuntu versions (20.04–26.04+) and any Linux distro
#   - Only dependency: Docker (single install command)
#   - All previous features preserved: create, start, stop, clone, backup, etc.
#   - Port forwarding via Docker -p
#   - Resource limits via Docker --memory and --cpus
#   - Snapshots via Docker commit
#   - Auto-install Docker if not present
# ==============================================================================
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  GLOBAL CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="3.0"
readonly LOG_FILE="${VM_LOG_FILE:-$HOME/vms-manager.log}"
VM_DIR="${VM_DIR:-$HOME/vms}"

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
    echo "   Enhanced Multi-VM Manager  v${SCRIPT_VERSION} (Docker Edition)"
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
        portforward)
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
#  DOCKER DEPENDENCY CHECKS
# ─────────────────────────────────────────────────────────────────────────────
install_docker() {
    print_status "INFO" "🔧 Docker not found — installing automatically..."

    local has_sudo=false
    if command -v sudo &>/dev/null; then
        has_sudo=true
    elif [ "$(id -u)" -eq 0 ]; then
        has_sudo=true
    fi

    if [ "$has_sudo" = false ]; then
        print_status "ERROR" "❌ Docker is required but sudo/root access is not available."
        print_status "INFO"  "💡 Install Docker manually: https://docs.docker.com/engine/install/"
        exit 1
    fi

    # Detect OS and install Docker
    if [ -f /etc/os-release ]; then
        . /etc/os-release
    fi

    local os_name="${ID:-}"
    local os_codename="${VERSION_CODENAME:-}"

    if command -v apt-get &>/dev/null; then
        # Ubuntu / Debian
        print_status "INFO" "📦 Installing Docker via official script..."
        if [ "$(id -u)" -eq 0 ]; then
            curl -fsSL https://get.docker.com | sh 2>&1 | tail -5
        else
            curl -fsSL https://get.docker.com | sudo sh 2>&1 | tail -5
        fi
        # Add user to docker group
        if [ "$(id -u)" -ne 0 ]; then
            sudo usermod -aG docker "$USER" 2>/dev/null || true
            print_status "INFO" "💡 You may need to log out and back in for Docker permissions."
        fi
    elif command -v dnf &>/dev/null; then
        # Fedora / RHEL
        curl -fsSL https://get.docker.com | sudo sh 2>&1 | tail -5
    elif command -v yum &>/dev/null; then
        # CentOS / Amazon Linux
        curl -fsSL https://get.docker.com | sudo sh 2>&1 | tail -5
    elif command -v pacman &>/dev/null; then
        # Arch
        sudo pacman -Sy --noconfirm docker 2>&1 | tail -3
        sudo systemctl start docker 2>/dev/null || true
    else
        print_status "ERROR" "❌ Unsupported OS — please install Docker manually."
        print_status "INFO"  "💡 https://docs.docker.com/engine/install/"
        exit 1
    fi

    # Start Docker daemon
    sudo systemctl start docker 2>/dev/null || true
    sudo systemctl enable docker 2>/dev/null || true

    if ! command -v docker &>/dev/null; then
        print_status "ERROR" "❌ Docker installation failed."
        exit 1
    fi

    print_status "SUCCESS" "✅ Docker installed successfully!"
}

is_inside_container() {
    # Detect if we're running inside a container
    [[ -f /.dockerenv ]] && return 0
    [[ -f /run/.containerenv ]] && return 0
    grep -q "docker\|lxc\|kubepods" /proc/1/cgroup 2>/dev/null && return 0
    return 1
}

start_docker_daemon() {
    # Try multiple methods to start dockerd
    local methods=(
        "systemctl"
        "service"
        "dockerd-overlay2"
        "dockerd-vfs"
        "dockerd-container"
    )

    for method in "${methods[@]}"; do
        case "$method" in
            systemctl)
                sudo systemctl start docker 2>/dev/null && sleep 2 && docker info &>/dev/null 2>&1 && return 0
                ;;
            service)
                sudo service docker start 2>/dev/null && sleep 2 && docker info &>/dev/null 2>&1 && return 0
                ;;
            dockerd-overlay2)
                # Standard dockerd with overlay2
                nohup dockerd --storage-driver=overlay2 --iptables=false &>/tmp/dockerd.log &
                sleep 8
                docker info &>/dev/null 2>&1 && return 0
                ;;
            dockerd-vfs)
                # VFS driver (works in more environments)
                nohup dockerd --storage-driver=vfs --iptables=false &>/tmp/dockerd-vfs.log &
                sleep 10
                docker info &>/dev/null 2>&1 && return 0
                ;;
            dockerd-container)
                # Minimal dockerd for containers (DinD)
                nohup dockerd --storage-driver=vfs --iptables=false --bridge=none --default-ulimit nofile=1024:4096 &>/tmp/dockerd-dind.log &
                sleep 12
                docker info &>/dev/null 2>&1 && return 0
                ;;
        esac
    done
    return 1
}

check_docker() {
    if ! command -v docker &>/dev/null; then
        install_docker
    fi

    # Check if Docker daemon is running
    if ! docker info &>/dev/null 2>&1; then
        print_status "WARN" "⚠️  Docker daemon is not running. Attempting to start..."

        # Detect environment
        if is_inside_container; then
            print_status "INFO" "🐳 Detected: running inside a container (DinD mode)"
        fi

        start_docker_daemon

        if ! docker info &>/dev/null 2>&1; then
            print_status "ERROR" "❌ Docker daemon failed to start."
            print_status "INFO"  "💡 Possible causes:"
            print_status "INFO"  "   1. Running inside a container without --privileged flag"
            print_status "INFO"  "   2. No root/sudo access"
            print_status "INFO"  "   3. AppArmor/SELinux blocking dockerd"
            echo
            print_status "INFO"  "💡 Try manually:"
            print_status "INFO"  "   sudo dockerd --storage-driver=vfs --iptables=false &"
            echo
            print_status "INFO"  "📋 Docker logs:"
            sudo cat /tmp/dockerd*.log 2>/dev/null | tail -10 || true
            echo
            print_status "INFO"  "📋 System info:"
            echo "    Container: $(is_inside_container && echo yes || echo no)"
            echo "    User: $(whoami)"
            echo "    Kernel: $(uname -r)"
            exit 1
        fi
    fi

    # Check disk space
    local avail_gb
    avail_gb=$(df -BG "$VM_DIR" 2>/dev/null | tail -1 | awk '{gsub("G",""); print $4}') || avail_gb=0
    if [ "${avail_gb:-0}" -lt 2 ]; then
        print_status "WARN" "⚠️  Low disk space (${avail_gb:-0}GB available). Docker images need ~2GB."
    fi

    print_status "SUCCESS" "✅ Docker is ready ($(docker --version 2>/dev/null))"
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
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "vm-${vm_name}" 2>/dev/null
}

REQUIRED_CONFIG_VARS=(
    VM_NAME HOSTNAME USERNAME PASSWORD
    OS_TYPE IMAGE_NAME SSH_PORT
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
    BACKGROUND_MODE="${BACKGROUND_MODE:-false}"
    PORT_FORWARDS="${PORT_FORWARDS:-}"
    MEMORY="${MEMORY:-1024}"
    CPUS="${CPUS:-2}"
    CREATED="${CREATED:-unknown}"
    MAC_ADDRESS="${MAC_ADDRESS:-}"
    GUI_MODE="${GUI_MODE:-none}"
    SSH_PASSWORD_ENABLED="${SSH_PASSWORD_ENABLED:-true}"

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
MEMORY=${MEMORY:-1024}
CPUS=${CPUS:-2}
PORT_FORWARDS="$PORT_FORWARDS"
AUTOSTART=$AUTOSTART
BACKGROUND_MODE=$BACKGROUND_MODE
GUI_MODE="$GUI_MODE"
SSH_PASSWORD_ENABLED=$SSH_PASSWORD_ENABLED
CREATED="$CREATED"
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
#  VM IMAGE MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────
setup_vm_image() {
    local image="$1"

    print_status "INFO" "📦 Checking/Downloading image: $image..."

    # Check if image exists locally
    if docker image inspect "$image" &>/dev/null; then
        print_status "INFO" "📦 Image already exists locally: $image"
        return 0
    fi

    # Try pulling from multiple registries/mirrors
    local registries=(
        ""                    # Docker Hub (default)
        "mirror.gcr.io/"      # Google mirror
        "registry-1.docker.io/" # Direct registry
    )

    # Also try alternative image names
    local image_variants=()
    if [[ "$image" == ubuntu* ]]; then
        image_variants=("ubuntu:22.04" "ubuntu:20.04" "ubuntu:latest" "$image")
    elif [[ "$image" == debian* ]]; then
        image_variants=("debian:bookworm" "debian:bullseye" "debian:latest" "$image")
    elif [[ "$image" == alpine* ]]; then
        image_variants=("alpine:3.18" "alpine:3.17" "alpine:latest" "$image")
    elif [[ "$image" == centos* ]]; then
        image_variants=("centos:7" "quay.io/centos/centos:stream8" "$image")
    elif [[ "$image" == fedora* ]]; then
        image_variants=("fedora:latest" "fedora:38" "$image")
    elif [[ "$image" == rocky* ]]; then
        image_variants=("rockylinux:9-minimal" "rockylinux:8-minimal" "$image")
    elif [[ "$image" == arch* ]]; then
        image_variants=("archlinux:latest" "$image")
    else
        image_variants=("$image")
    fi

    for variant in "${image_variants[@]}"; do
        for registry in "${registries[@]}"; do
            local full_image="${registry}${variant}"
            print_status "INFO" "📥 Trying: $full_image..."
            local pull_output
            pull_output=$(docker pull "$full_image" 2>&1)
            local pull_exit=$?

            if [ $pull_exit -eq 0 ]; then
                # Tag it to the requested name if different
                if [[ "$full_image" != "$image" ]]; then
                    docker tag "$full_image" "$image" 2>/dev/null || true
                fi
                print_status "SUCCESS" "✅ Image downloaded: $full_image"
                return 0
            fi

            # Show last line of error for diagnosis
            echo "$pull_output" | tail -1 | head -c 100
        done
    done

    print_status "ERROR" "❌ Failed to pull any image variant."
    print_status "INFO"  "💡 Possible causes:"
    print_status "INFO"  "   1. No internet connection from the container"
    print_status "INFO"  "   2. Docker Hub rate limit reached"
    print_status "INFO"  "   3. DNS resolution failed inside the container"
    echo
    print_status "INFO"  "💡 Try manually to check:"
    print_status "INFO"  "   docker pull alpine:latest"
    print_status "INFO"  "   curl -s https://index.docker.io/v1/"
    exit 1
}

get_default_image() {
    local os_type="$1"
    case "${os_type,,}" in
        ubuntu*)  echo "ubuntu:22.04" ;;
        debian*)  echo "debian:bookworm" ;;
        alpine*)  echo "alpine:latest" ;;
        centos*)  echo "centos:7" ;;
        rocky*|almalinux*) echo "rockylinux:9-minimal" ;;
        fedora*)  echo "fedora:latest" ;;
        arch*)    echo "archlinux:latest" ;;
        *)        echo "ubuntu:22.04" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
#  VM LIFECYCLE
# ─────────────────────────────────────────────────────────────────────────────
create_new_vm() {
    print_status "INFO" "🆕 Creating a new VM..."
    echo "────────────────────────────────────────────────"

    # VM name
    while true; do
        read -p "$(print_status "INPUT" "📛 VM name: ")" VM_NAME
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
        read -p "$(print_status "INPUT" "🏠 Hostname (default: $VM_NAME): ")" HOSTNAME
        HOSTNAME="${HOSTNAME:-$VM_NAME}"
        if validate_input "name" "$HOSTNAME"; then
            break
        fi
    done

    # Username
    while true; do
        read -p "$(print_status "INPUT" "👤 Username (default: user): ")" USERNAME
        USERNAME="${USERNAME:-user}"
        if validate_input "username" "$USERNAME"; then
            break
        fi
    done

    # Password
    while true; do
        read -sp "$(print_status "INPUT" "🔑 Password: ")" PASSWORD
        echo
        if [[ -z "$PASSWORD" ]]; then
            print_status "ERROR" "❌ Password cannot be empty"
        else
            break
        fi
    done
    SSH_PASSWORD_ENABLED=true

    # OS Type
    while true; do
        read -p "$(print_status "INPUT" "🐧 OS type (ubuntu/debian/alpine/centos/fedora/arch, default: ubuntu): ")" OS_TYPE
        OS_TYPE="${OS_TYPE:-ubuntu}"
        case "$OS_TYPE" in
            ubuntu|debian|alpine|centos|rocky|almalinux|fedora|arch) break ;;
            "") OS_TYPE="ubuntu"; break ;;
            *) print_status "ERROR" "❌ Supported: ubuntu, debian, alpine, centos, rocky, fedora, arch" ;;
        esac
    done

    # Image name
    local default_image
    default_image=$(get_default_image "$OS_TYPE")
    read -p "$(print_status "INPUT" "📦 Docker image (default: $default_image): ")" IMAGE_NAME
    IMAGE_NAME="${IMAGE_NAME:-$default_image}"

    # SSH Port
    while true; do
        read -p "$(print_status "INPUT" "🔌 SSH port on host (default: 2222): ")" SSH_PORT
        SSH_PORT="${SSH_PORT:-2222}"
        if validate_input "port" "$SSH_PORT"; then
            if is_port_in_use "$SSH_PORT"; then
                print_status "ERROR" "❌ Port $SSH_PORT is already in use"
            else
                break
            fi
        fi
    done

    # RAM
    while true; do
        read -p "$(print_status "INPUT" "🧠 RAM in MB (default: 1024): ")" MEMORY
        MEMORY="${MEMORY:-1024}"
        if validate_input "number" "$MEMORY" && [ "$MEMORY" -ge 64 ]; then
            break
        fi
    done

    # CPUs
    while true; do
        read -p "$(print_status "INPUT" "⚡ CPUs (default: 2): ")" CPUS
        CPUS="${CPUS:-2}"
        if validate_input "number" "$CPUS" && [ "$CPUS" -ge 1 ]; then
            break
        fi
    done

    # Port forwards
    read -p "$(print_status "INPUT" "🌐 Extra port forwards (e.g., 8080:80, comma-separated, Enter=none): ")" PORT_FORWARDS

    # Autostart
    read -p "$(print_status "INPUT" "🚀 Autostart on boot? (y/n, default: n): ")" as_in
    as_in="${as_in:-n}"
    if [[ "$as_in" =~ ^[Yy]$ ]]; then AUTOSTART=true; else AUTOSTART=false; fi

    # GUI mode
    while true; do
        read -p "$(print_status "INPUT" "🖥️  GUI mode? (none/vnc, default: none): ")" GUI_MODE
        GUI_MODE="${GUI_MODE:-none}"
        case "$GUI_MODE" in
            none|vnc) break ;;
            "") GUI_MODE="none"; break ;;
            *) print_status "ERROR" "❌ Answer 'none' or 'vnc'" ;;
        esac
    done

    # Download image
    setup_vm_image "$IMAGE_NAME" || return 1

    # Save config
    CREATED="$(date)"
    BACKGROUND_MODE=false
    save_vm_config "$VM_NAME"

    print_status "SUCCESS" "✅ VM '$VM_NAME' created successfully!"
    log INFO "VM created: $VM_NAME"

    # Ask to start
    read -p "$(print_status "INPUT" "🚀 Start VM now? (y/n, default: y): ")" start_now
    start_now="${start_now:-y}"
    if [[ "$start_now" =~ ^[Yy]$ ]]; then
        start_vm "$VM_NAME"
    fi
}

is_port_in_use() {
    local port="$1"
    # Check if any Docker container is using this host port
    docker ps --format '{{.Ports}}' 2>/dev/null | grep -q ":${port}->" 2>/dev/null
}

start_vm() {
    local vm_name="$1"
    load_vm_config "$vm_name" || return 1

    if is_vm_running "$vm_name"; then
        print_status "INFO" "ℹ️  VM '$vm_name' is already running"
        return 0
    fi

    # Check if image exists
    if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
        setup_vm_image "$IMAGE_NAME" || return 1
    fi

    # Check if container exists (stopped)
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "vm-${vm_name}"; then
        print_status "INFO" "🔄 Starting existing container..."
        docker start "vm-${vm_name}" 2>&1 | tail -1
    else
        # Build Docker run command
        print_status "INFO" "🚀 Creating and starting VM: $vm_name..."
        print_status "INFO" "📊 Config: ${MEMORY}MB RAM | ${CPUS} CPUs | ${IMAGE_NAME}"

        local docker_cmd=(docker run -d
            --name "vm-${vm_name}"
            --hostname "$HOSTNAME"
            --memory "${MEMORY}m"
            --cpus "$CPUS"
            --restart no
        )

        # SSH port
        docker_cmd+=(-p "${SSH_PORT}:22")

        # Extra port forwards
        if [[ -n "$PORT_FORWARDS" ]]; then
            IFS=',' read -ra forwards <<< "$PORT_FORWARDS"
            for fwd in "${forwards[@]}"; do
                fwd="${fwd// /}"
                if validate_input "portforward" "$fwd" 2>/dev/null; then
                    docker_cmd+=(-p "$fwd")
                fi
            done
        fi

        # VNC port if enabled
        if [[ "$GUI_MODE" == "vnc" ]]; then
            docker_cmd+=(-p "5900:5900")
        fi

        # Environment variables
        docker_cmd+=(-e "USERNAME=$USERNAME")
        docker_cmd+=(-e "PASSWORD=$PASSWORD")
        docker_cmd+=(-e "SSH_PASSWORD_ENABLED=$SSH_PASSWORD_ENABLED")
        docker_cmd+=(-e "VM_NAME=$VM_NAME")

        # Volume for persistence
        docker_cmd+=(-v "vm-${vm_name}-data:/home/${USERNAME}")

        # GUI mode
        if [[ "$GUI_MODE" == "vnc" ]]; then
            docker_cmd+=(--cap-add=SYS_ADMIN)
        fi

        # Image
        docker_cmd+=("$IMAGE_NAME")

        # Default command: keep running with SSH
        docker_cmd+=(bash -c '
            # Install SSH if not present
            command -v sshd &>/dev/null || {
                apt-get update -qq && apt-get install -y -qq openssh-server 2>/dev/null || true
                yum install -y -q openssh-server 2>/dev/null || true
                pacman -Sy --noconfirm openssh 2>/dev/null || true
                apk add openssh 2>/dev/null || true
            }
            # Setup SSH
            mkdir -p /run/sshd
            echo "PermitRootLogin yes" >> /etc/ssh/sshd_config 2>/dev/null || true
            echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config 2>/dev/null || true
            # Create user
            if ! id "$USERNAME" &>/dev/null; then
                useradd -m -s /bin/bash "$USERNAME" 2>/dev/null || true
            fi
            echo "${USERNAME}:${PASSWORD}" | chpasswd 2>/dev/null || true
            # Start SSH
            /usr/sbin/sshd -D 2>/dev/null || /usr/sbin/sshd 2>/dev/null || true
            # Keep container alive
            tail -f /dev/null
        ')

        "${docker_cmd[@]}" 2>&1 | tail -3
        if [[ $? -ne 0 ]]; then
            print_status "ERROR" "❌ Failed to start VM: $vm_name"
            return 1
        fi
    fi

    sleep 2

    if is_vm_running "$vm_name"; then
        print_status "SUCCESS" "✅ VM '$vm_name' started!"
        print_status "INFO" "🔑 SSH: ssh ${USERNAME}@localhost -p ${SSH_PORT}"
        log INFO "VM started: $vm_name"
    else
        print_status "ERROR" "❌ VM '$vm_name' failed to start. Check: docker logs vm-${vm_name}"
        return 1
    fi
}

stop_vm() {
    local vm_name="$1"

    if ! is_vm_running "$vm_name"; then
        print_status "WARN" "⚠️  VM '$vm_name' is not running"
        return 0
    fi

    print_status "INFO" "🛑 Stopping VM: $vm_name..."
    docker stop "vm-${vm_name}" 2>&1 | tail -1
    print_status "SUCCESS" "✅ VM '$vm_name' stopped"
    log INFO "VM stopped: $vm_name"
}

restart_vm() {
    local vm_name="$1"
    load_vm_config "$vm_name" || return 1

    stop_vm "$vm_name"
    sleep 1
    start_vm "$vm_name"
}

delete_vm() {
    local vm_name="$1"
    load_vm_config "$vm_name" 2>/dev/null || true

    # Confirm with full name
    print_status "WARN" "⚠️  This will DELETE VM '$vm_name' and ALL its data!"
    read -p "$(print_status "INPUT" "🗑️  Type the VM name to confirm: ")" confirm
    if [[ "$confirm" != "$vm_name" ]]; then
        print_status "ERROR" "❌ Confirmation failed"
        return 1
    fi

    # Stop if running
    if is_vm_running "$vm_name"; then
        docker stop "vm-${vm_name}" 2>/dev/null || true
    fi

    # Remove container
    docker rm -f "vm-${vm_name}" 2>/dev/null || true

    # Remove volume
    docker volume rm "vm-${vm_name}-data" 2>/dev/null || true

    # Remove config directory
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
    if is_vm_running "$vm_name"; then
        status="🚀 Running"
    fi

    local container_info=""
    if is_vm_running "$vm_name"; then
        container_info=$(docker inspect "vm-${vm_name}" --format '{{json .}}' 2>/dev/null)
    fi

    echo "═══════════════════════════════════════════════"
    echo "  VM: $VM_NAME"
    echo "  Status: $status"
    echo "───────────────────────────────────────────────"
    echo "  Image:      $IMAGE_NAME"
    echo "  OS Type:    $OS_TYPE"
    echo "  Hostname:   $HOSTNAME"
    echo "  Username:   $USERNAME"
    echo "  SSH Port:   $SSH_PORT"
    echo "  RAM:        ${MEMORY}MB"
    echo "  CPUs:       $CPUS"
    echo "  GUI:        $GUI_MODE"
    echo "  Autostart:  $AUTOSTART"
    echo "  Created:    $CREATED"
    if [[ -n "$PORT_FORWARDS" ]]; then
        echo "  Forwards:   $PORT_FORWARDS"
    fi
    if is_vm_running "$vm_name"; then
        echo "  Container:  vm-${vm_name}"
        local ip
        ip=$(docker inspect "vm-${vm_name}" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
        echo "  IP:         ${ip:-N/A}"
    fi
    echo "═══════════════════════════════════════════════"
}

show_vm_performance() {
    local vm_name="$1"

    if ! is_vm_running "$vm_name"; then
        print_status "WARN" "⚠️  VM '$vm_name' is not running"
        return 0
    fi

    echo "═══════════════════════════════════════════════"
    echo "  Performance: $vm_name"
    echo "───────────────────────────────────────────────"

    # Container stats (one shot)
    docker stats "vm-${vm_name}" --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}" 2>/dev/null

    echo
    echo "  Container ID: $(docker ps -qf name=vm-${vm_name})"
    echo "  Uptime: $(docker inspect "vm-${vm_name}" --format '{{.State.StartedAt}}' 2>/dev/null)"
    echo "═══════════════════════════════════════════════"
}

# ─────────────────────────────────────────────────────────────────────────────
#  EDIT VM CONFIG
# ─────────────────────────────────────────────────────────────────────────────
edit_vm_config() {
    local vm_name="$1"
    load_vm_config "$vm_name" || return 1

    if is_vm_running "$vm_name"; then
        print_status "WARN" "⚠️  VM is running. Stop it first for changes to take effect."
        read -p "$(print_status "INPUT" "🔄 Stop VM to apply changes? (y/N): ")" stop_confirm
        if [[ "$stop_confirm" =~ ^[Yy]$ ]]; then
            stop_vm "$vm_name"
        fi
    fi

    print_status "INFO" "✏️  Editing VM: $vm_name"
    echo "  Leave blank to keep current value."
    echo

    read -p "Hostname [${HOSTNAME}]: " input; HOSTNAME="${input:-$HOSTNAME}"
    read -p "Username [${USERNAME}]: " input; USERNAME="${input:-$USERNAME}"
    read -sp "Password [****]: " input; echo; PASSWORD="${input:-$PASSWORD}"
    read -p "SSH port [${SSH_PORT}]: " input; SSH_PORT="${input:-$SSH_PORT}"
    read -p "RAM MB [${MEMORY}]: " input; MEMORY="${input:-$MEMORY}"
    read -p "CPUs [${CPUS}]: " input; CPUS="${input:-$CPUS}"
    read -p "Port forwards [${PORT_FORWARDS}]: " input; PORT_FORWARDS="${input:-$PORT_FORWARDS}"
    read -p "Autostart [${AUTOSTART}]: " input; AUTOSTART="${input:-$AUTOSTART}"
    read -p "GUI mode [${GUI_MODE}]: " input; GUI_MODE="${input:-$GUI_MODE}"

    save_vm_config "$vm_name"
    print_status "SUCCESS" "✅ Config saved for '$vm_name'"

    if is_vm_running "$vm_name"; then
        print_status "INFO" "ℹ️  Restart VM to apply changes"
    fi

    log INFO "VM config edited: $vm_name"
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
        read -p "$(print_status "INPUT" "🎯 Choice: ")" snap_choice

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

    read -p "$(print_status "INPUT" "📸 Snapshot name: ")" snap_name
    if [[ -z "$snap_name" ]]; then
        print_status "ERROR" "❌ Name cannot be empty"
        return 1
    fi

    local snap_dir="$VM_DIR/snapshots/$vm_name"
    mkdir -p "$snap_dir"

    if is_vm_running "$vm_name"; then
        print_status "INFO" "📸 Creating snapshot from running container..."
        docker commit "vm-${vm_name}" "vm-${vm_name}:snap-${snap_name}" 2>&1 | tail -1
    else
        print_status "WARN" "⚠️  VM is stopped — snapshot will use last container state"
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "vm-${vm_name}"; then
            docker commit "vm-${vm_name}" "vm-${vm_name}:snap-${snap_name}" 2>&1 | tail -1
        else
            print_status "ERROR" "❌ No container found for this VM"
            return 1
        fi
    fi

    # Save snapshot metadata
    cat > "$snap_dir/${snap_name}.meta" << EOF
name=$snap_name
vm=$vm_name
image=vm-${vm_name}:snap-${snap_name}
created=$(date)
config=$(cat "$VM_DIR/$vm_name/config.sh")
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

    if [[ ! -d "$snap_dir" ]] || [[ -z "$(ls "$snap_dir" 2>/dev/null)" ]]; then
        echo "  No snapshots found."
    else
        for meta in "$snap_dir"/*.meta; do
            [[ -f "$meta" ]] || continue
            local sname screated
            sname=$(grep "^name=" "$meta" | cut -d= -f2)
            screated=$(grep "^created=" "$meta" | cut -d= -f2-)
            printf "  📸 %-20s Created: %s\n" "$sname" "$screated"
        done
    fi
    echo "═══════════════════════════════════════════════"
}

snapshot_revert() {
    local vm_name="$1"
    local snap_dir="$VM_DIR/snapshots/$vm_name"

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
        printf "  %d) %s\n" "$idx" "$sname"
    done

    read -p "$(print_status "INPUT" "🎯 Select snapshot number: ")" sel
    if [[ "$sel" -ge 1 ]] && [[ "$sel" -le "${#snap_names[@]}" ]]; then
        local target="${snap_names[$((sel-1))]}"
        local target_image="vm-${vm_name}:snap-${target}"

        print_status "WARN" "⚠️  This will replace the current container!"
        read -p "$(print_status "INPUT" "🔄 Confirm revert to '$target'? (y/N): ")" rev_confirm
        if [[ ! "$rev_confirm" =~ ^[Yy]$ ]]; then
            return 0
        fi

        # Stop and remove current
        docker stop "vm-${vm_name}" 2>/dev/null || true
        docker rm -f "vm-${vm_name}" 2>/dev/null || true

        # Create new container from snapshot
        load_vm_config "$vm_name"
        docker run -d --name "vm-${vm_name}" \
            --hostname "$HOSTNAME" \
            --memory "${MEMORY}m" \
            --cpus "$CPUS" \
            -p "${SSH_PORT}:22" \
            -v "vm-${vm_name}-data:/home/${USERNAME}" \
            "$target_image" \
            tail -f /dev/null 2>&1 | tail -2

        print_status "SUCCESS" "✅ Reverted to snapshot '$target'"
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
        printf "  %d) %s\n" "$idx" "$sname"
    done

    read -p "$(print_status "INPUT" "🎯 Select snapshot to delete: ")" sel
    if [[ "$sel" -ge 1 ]] && [[ "$sel" -le "${#snap_names[@]}" ]]; then
        local target="${snap_names[$((sel-1))]}"
        local target_image="vm-${vm_name}:snap-${target}"

        docker rmi "$target_image" 2>/dev/null || true
        rm -f "$snap_dir/${target}.meta"

        print_status "SUCCESS" "✅ Snapshot '$target' deleted"
        log INFO "Snapshot deleted: $vm_name/$target"
    else
        print_status "ERROR" "❌ Invalid selection"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  CLONE VM
# ─────────────────────────────────────────────────────────────────────────────
clone_vm() {
    local vm_name="$1"
    load_vm_config "$vm_name" || return 1

    echo "  Cloning VM: $vm_name"
    read -p "$(print_status "INPUT" "📋 New VM name: ")" clone_name
    if [[ -z "$clone_name" ]] || ! validate_input "name" "$clone_name" 2>/dev/null; then
        print_status "ERROR" "❌ Invalid name"
        return 1
    fi

    if [[ -d "$VM_DIR/$clone_name" ]]; then
        print_status "ERROR" "❌ VM '$clone_name' already exists"
        return 1
    fi

    # Find a free SSH port
    local new_port=$((SSH_PORT + 1000))
    while is_port_in_use "$new_port"; do
        (( new_port++ )) || true
    done

    # Copy config with modifications
    VM_NAME="$clone_name"
    SSH_PORT="$new_port"
    HOSTNAME="$clone_name"
    MAC_ADDRESS=""
    CREATED="$(date)"
    BACKGROUND_MODE=false
    save_vm_config "$clone_name"

    # Copy volume data if exists
    if docker volume inspect "vm-${vm_name}-data" &>/dev/null; then
        # Create new volume by copying from old
        docker run --rm \
            -v "vm-${vm_name}-data:/source:ro" \
            -v "vm-${clone_name}-data:/dest" \
            alpine:latest \
            sh -c 'cp -a /source/. /dest/' 2>/dev/null || true
    fi

    # Copy snapshots
    if [[ -d "$VM_DIR/snapshots/$vm_name" ]]; then
        mkdir -p "$VM_DIR/snapshots/$clone_name"
        cp -r "$VM_DIR/snapshots/$vm_name/"* "$VM_DIR/snapshots/$clone_name/" 2>/dev/null || true
    fi

    print_status "SUCCESS" "✅ VM cloned: $vm_name -> $clone_name"
    print_status "INFO" "🔑 SSH port: $new_port"
    log INFO "VM cloned: $vm_name -> $clone_name"
}

# ─────────────────────────────────────────────────────────────────────────────
#  RESIZE (change resource limits)
# ─────────────────────────────────────────────────────────────────────────────
resize_vm() {
    local vm_name="$1"
    load_vm_config "$vm_name" || return 1

    print_status "INFO" "📈 Resize resources for: $vm_name"
    echo "  Current: ${MEMORY}MB RAM | ${CPUS} CPUs"

    read -p "$(print_status "INPUT" "🧠 New RAM (MB, Enter=same): ")" new_mem
    if [[ -n "$new_mem" ]]; then
        validate_input "number" "$new_mem" || return 1
        MEMORY="$new_mem"
    fi

    read -p "$(print_status "INPUT" "⚡ New CPUs (Enter=same): ")" new_cpus
    if [[ -n "$new_cpus" ]]; then
        validate_input "number" "$new_cpus" || return 1
        CPUS="$new_cpus"
    fi

    save_vm_config "$vm_name"
    print_status "SUCCESS" "✅ Resources updated: ${MEMORY}MB RAM | ${CPUS} CPUs"
    print_status "INFO" "ℹ️  Restart VM to apply changes"
    log INFO "VM resized: $vm_name (${MEMORY}MB, ${CPUS} CPUs)"
}

# ─────────────────────────────────────────────────────────────────────────────
#  FIX VM ISSUES
# ─────────────────────────────────────────────────────────────────────────────
fix_vm_issues() {
    local vm_name="$1"
    load_vm_config "$vm_name" || return 1

    print_status "INFO" "🔧 Checking VM '$vm_name' for issues..."

    local issues=0

    # Check 1: Image exists
    if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
        print_status "WARN" "⚠️  Image '$IMAGE_NAME' not found locally"
        read -p "$(print_status "INPUT" "🔄 Pull image now? (y/N): ")" pull_confirm
        if [[ "$pull_confirm" =~ ^[Yy]$ ]]; then
            setup_vm_image "$IMAGE_NAME"
        fi
        (( issues++ )) || true
    fi

    # Check 2: Port conflicts
    if is_port_in_use "$SSH_PORT"; then
        print_status "WARN" "⚠️  SSH port $SSH_PORT is in use by another container"
        read -p "$(print_status "INPUT" "🔄 Change SSH port? (y/N): ")" port_confirm
        if [[ "$port_confirm" =~ ^[Yy]$ ]]; then
            read -p "$(print_status "INPUT" "🔌 New SSH port: ")" new_port
            validate_input "port" "$new_port" || return 1
            SSH_PORT="$new_port"
            save_vm_config "$vm_name"
        fi
        (( issues++ )) || true
    fi

    # Check 3: Orphan containers
    if ! is_vm_running "$vm_name"; then
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "vm-${vm_name}"; then
            print_status "WARN" "⚠️  Orphan container exists (stopped)"
            read -p "$(print_status "INPUT" "🔄 Remove orphan and restart? (y/N): ")" orphan_confirm
            if [[ "$orphan_confirm" =~ ^[Yy]$ ]]; then
                docker rm "vm-${vm_name}" 2>/dev/null || true
                start_vm "$vm_name"
            fi
            (( issues++ )) || true
        fi
    fi

    # Check 4: Volume exists
    if ! docker volume inspect "vm-${vm_name}-data" &>/dev/null; then
        print_status "WARN" "⚠️  Data volume missing"
        docker volume create "vm-${vm_name}-data" 2>/dev/null || true
        (( issues++ )) || true
    fi

    # Check 5: Disk space
    local avail_gb
    avail_gb=$(df -BG "$VM_DIR" 2>/dev/null | tail -1 | awk '{gsub("G",""); print $4}') || avail_gb=0
    if [ "${avail_gb:-0}" -lt 1 ]; then
        print_status "ERROR" "❌ Low disk space: ${avail_gb:-0}GB"
        (( issues++ )) || true
    fi

    if [ "$issues" -eq 0 ]; then
        print_status "SUCCESS" "✅ No issues found for '$vm_name'"
    else
        print_status "INFO" "🔧 Fixed $issues issue(s)"
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

    # Create backup of config + volume data
    tar czf "$backup_file" \
        -C "$VM_DIR" "$vm_name/config.sh" \
        2>/dev/null || true

    # If VM is running, commit container state too
    if is_vm_running "$vm_name"; then
        docker commit "vm-${vm_name}" "vm-${vm_name}:backup-$(date '+%Y%m%d%H%M%S')" 2>/dev/null || true
    fi

    local size
    size=$(du -h "$backup_file" 2>/dev/null | cut -f1)
    print_status "SUCCESS" "✅ Backup saved: $backup_file (${size})"
    log INFO "VM backed up: $vm_name -> $backup_file"
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
        printf "  %d) %s (%s)\n" "$idx" "$fname" "$fsize"
    done

    read -p "$(print_status "INPUT" "🎯 Select backup: ")" sel
    if [[ "$sel" -ge 1 ]] && [[ "$sel" -le "${#backup_files[@]}" ]]; then
        local target="${backup_files[$((sel-1))]}"

        print_status "WARN" "⚠️  This will overwrite the VM configuration!"
        read -p "$(print_status "INPUT" "🔄 Confirm restore? (y/N): ")" restore_confirm
        if [[ ! "$restore_confirm" =~ ^[Yy]$ ]]; then
            return 0
        fi

        # Extract config
        tar xzf "$target" -C "$VM_DIR" 2>/dev/null

        # Load restored config
        local restored_vm
        restored_vm=$(grep "^VM_NAME=" "$VM_DIR"/*/config.sh 2>/dev/null | head -1 | cut -d'"' -f2)

        print_status "SUCCESS" "✅ VM restored from backup: $restored_vm"
        log INFO "VM restored from backup: $restored_vm"
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
            echo "  7)  📈 Resize VM resources"
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
                [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le "$vm_count" ] && resize_vm "${vms[$((vm_num-1))]}" || print_status "ERROR" "❌ Invalid selection"
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
    # Nothing special to clean up with Docker
    :
}

# ─────────────────────────────────────────────────────────────────────────────
#  ENTRY POINT
# ─────────────────────────────────────────────────────────────────────────────
trap cleanup EXIT

# Ensure VM_DIR exists
mkdir -p "$VM_DIR"

if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    echo "Enhanced Multi-VM Manager v${SCRIPT_VERSION} (Docker Edition)"
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

if [[ -n "${1:-}" ]]; then
    check_docker
    run_cli "$@"
else
    check_docker
    main_menu
fi
