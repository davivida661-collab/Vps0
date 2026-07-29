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
