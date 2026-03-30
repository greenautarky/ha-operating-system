#!/usr/bin/env bash
# setup-build-server.sh — Create and configure GA OS build server on Proxmox
#
# Usage:
#   ./scripts/setup-build-server.sh <proxmox-host> [ctid]
#
# Example:
#   ./scripts/setup-build-server.sh 192.168.1.33 107
#
# Prerequisites:
#   - SSH access to Proxmox host as root
#   - Proxmox VE 8.x
#   - At least 100 GB free on local-lvm
#
set -euo pipefail

PVE_HOST="${1:?Usage: $0 <proxmox-host> [ctid]}"
CTID="${2:-107}"
HOSTNAME="ga-builder"
TEMPLATE="debian-12-standard_12.12-1_amd64.tar.zst"
CORES=8
MEMORY=16384
SWAP=2048
DISK_SIZE=100  # GB

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

pve() { ssh $SSH_OPTS "root@${PVE_HOST}" "$@"; }
ct()  { pve "pct exec ${CTID} -- bash -c '$*'"; }

echo "=== GA OS Build Server Setup ==="
echo "  Proxmox host: ${PVE_HOST}"
echo "  Container ID: ${CTID}"
echo "  Resources:    ${CORES} vCPUs, ${MEMORY} MB RAM, ${DISK_SIZE} GB disk"
echo ""

# 1. Test connectivity
echo "[1/6] Testing Proxmox connectivity..."
PVE_VER=$(pve "pveversion") || { echo "ERROR: Cannot SSH to ${PVE_HOST}"; exit 1; }
echo "  Connected: ${PVE_VER}"

# 2. Download template
echo "[2/6] Ensuring template is available..."
if ! pve "ls /var/lib/vz/template/cache/${TEMPLATE}" &>/dev/null; then
    echo "  Downloading ${TEMPLATE}..."
    pve "pveam update && pveam download local ${TEMPLATE}"
else
    echo "  Template already cached"
fi

# 3. Create container
echo "[3/6] Creating LXC container ${CTID}..."
if pve "pct status ${CTID}" &>/dev/null; then
    echo "  Container ${CTID} already exists — skipping creation"
else
    pve "pct create ${CTID} local:vztmpl/${TEMPLATE} \
        --hostname ${HOSTNAME} \
        --cores ${CORES} \
        --memory ${MEMORY} \
        --swap ${SWAP} \
        --rootfs local-lvm:${DISK_SIZE} \
        --net0 name=eth0,bridge=vmbr0,ip=dhcp \
        --features nesting=1,keyctl=1 \
        --unprivileged 0 \
        --ostype debian \
        --start 1 \
        --onboot 1"
    echo "  Container created and started"
    sleep 5  # wait for boot
fi

# Ensure running
pve "pct start ${CTID}" 2>/dev/null || true
sleep 3

# 3b. Configure LXC for Docker-in-Docker (privileged mode)
echo "[3b/6] Configuring Docker-in-Docker capabilities..."
pve "pct stop ${CTID}" 2>/dev/null || true
sleep 2
# These settings are REQUIRED for Docker --privileged inside LXC:
# - apparmor unconfined: Docker needs to manage its own apparmor profiles
# - cgroup2.devices.allow: a: Docker needs device access
# - mount.auto cgroup:rw:force: Docker-in-Docker needs writable cgroups
# - cap.drop empty: Docker --privileged needs ALL capabilities
# - loop devices: Buildroot creates data.ext4 via losetup+mount
# - /dev/mapper: RAUC verity bundles need device-mapper (dm-verity)
pve "
cat >> /etc/pve/lxc/${CTID}.conf << 'LXCEOF'
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.mount.auto: proc:rw sys:rw
lxc.cap.drop:
lxc.mount.entry: /dev/loop-control dev/loop-control none bind,create=file 0 0
lxc.mount.entry: /dev/loop0 dev/loop0 none bind,create=file 0 0
lxc.mount.entry: /dev/loop1 dev/loop1 none bind,create=file 0 0
lxc.mount.entry: /dev/loop2 dev/loop2 none bind,create=file 0 0
lxc.mount.entry: /dev/loop3 dev/loop3 none bind,create=file 0 0
lxc.mount.entry: /dev/loop4 dev/loop4 none bind,create=file 0 0
lxc.mount.entry: /dev/loop5 dev/loop5 none bind,create=file 0 0
lxc.mount.entry: /dev/loop6 dev/loop6 none bind,create=file 0 0
lxc.mount.entry: /dev/loop7 dev/loop7 none bind,create=file 0 0
lxc.mount.entry: /dev/mapper dev/mapper none bind,create=dir 0 0
LXCEOF
"

# Load dm-verity kernel module on host (needed for RAUC bundle signing)
pve "modprobe dm_mod && modprobe dm-verity 2>/dev/null || modprobe dm_verity 2>/dev/null && echo 'dm-verity loaded' || echo 'WARN: dm-verity not available'"
pve "pct start ${CTID}"
sleep 10
echo "  Docker-in-Docker configured"

# 4. Install dependencies
echo "[4/6] Installing build dependencies..."
ct 'apt-get update -qq && apt-get install -y -qq \
    git docker.io curl jq skopeo xz-utils \
    automake bash bc binutils build-essential bzip2 cpio file \
    graphviz help2man make ncurses-dev openssh-client patch perl pigz \
    python3 python3-matplotlib python-is-python3 qemu-utils rsync \
    sudo texinfo unzip vim wget zip sshpass 2>&1 | tail -3'

# 5. Install Trivy
echo "[5/6] Installing Trivy..."
ct 'curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin 2>&1 | tail -1'

# 6. Install GitHub Actions Runner
echo "[6/6] Installing GitHub Actions Runner..."
ct 'mkdir -p /opt/actions-runner && cd /opt/actions-runner && \
    RUNNER_VERSION=$(curl -sf https://api.github.com/repos/actions/runner/releases/latest | grep tag_name | cut -d\" -f4 | sed s/v//) && \
    echo "Runner version: $RUNNER_VERSION" && \
    curl -sL https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz | tar xz && \
    echo "Runner installed"'

# Get container IP
CT_IP=$(pve "pct exec ${CTID} -- ip -4 addr show eth0 | grep inet | awk '{print \$2}' | cut -d/ -f1")

echo ""
echo "=== Setup Complete ==="
echo "  Container: ${CTID} (${HOSTNAME})"
echo "  IP:        ${CT_IP}"
echo "  SSH:       ssh root@${CT_IP}"
echo ""
echo "  Next steps:"
echo "    1. Configure GitHub Actions Runner:"
echo "       ssh root@${CT_IP}"
echo "       cd /opt/actions-runner"
echo "       ./config.sh --url https://github.com/greenautarky/ha-operating-system --token <TOKEN>"
echo "       ./svc.sh install && ./svc.sh start"
echo ""
echo "    2. Clone and build:"
echo "       ssh root@${CT_IP}"
echo "       git clone https://github.com/greenautarky/ha-operating-system.git /build"
echo "       cd /build && git submodule update --init"
echo "       ./scripts/ga_build.sh dev"
