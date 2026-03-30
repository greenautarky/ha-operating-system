# Build Server Setup (Proxmox LXC)

## Overview

A dedicated LXC container on the Proxmox host for building GA OS images.
Replaces building on the developer laptop — faster, consistent, and can
run as a self-hosted GitHub Actions runner.

## Current Setup

- **Host**: HomeS4 (192.168.1.33), Proxmox 8.4
- **Container**: CTID 107, hostname `ga-builder`
- **IP**: 172.16.10.249 (DHCP via vmbr0)
- **Resources**: 8 vCPUs, 16 GB RAM, 100 GB disk (local-lvm)
- **OS**: Debian 12 (Bookworm)

## LXC Container Creation

```bash
# On Proxmox host (192.168.1.33):

# 1. Download template (once)
pveam update
pveam download local debian-12-standard_12.12-1_amd64.tar.zst

# 2. Create container
pct create 107 local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst \
  --hostname ga-builder \
  --cores 8 \
  --memory 16384 \
  --swap 2048 \
  --rootfs local-lvm:100 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --features nesting=1,keyctl=1 \
  --unprivileged 0 \
  --ostype debian \
  --start 1 \
  --onboot 1

# 3. Configure Docker-in-Docker (CRITICAL for GA OS build)
# The build uses Docker-in-Docker (DinD) for data partition creation.
# These LXC settings are REQUIRED:
pct stop 107
cat >> /etc/pve/lxc/107.conf << 'EOF'
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.mount.auto: proc:rw sys:rw cgroup:rw:force
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
EOF
pct start 107

# 3b. Load dm-verity on host (needed for RAUC bundle signing)
modprobe dm_mod
modprobe dm-verity 2>/dev/null || modprobe dm_verity
# Make persistent:
echo dm_mod >> /etc/modules-load.d/ga-builder.conf
echo dm-verity >> /etc/modules-load.d/ga-builder.conf

# 4. Install build dependencies
pct exec 107 -- bash -c 'apt-get update && apt-get install -y \
  git docker.io curl jq skopeo xz-utils \
  automake bash bc binutils build-essential bzip2 cpio file \
  graphviz help2man make ncurses-dev openssh-client patch perl pigz \
  python3 python3-matplotlib python-is-python3 qemu-utils rsync \
  sudo texinfo unzip vim wget zip sshpass'

# 4. Install Trivy (CVE scanner)
pct exec 107 -- bash -c \
  'curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin'

# 5. Install GitHub Actions Runner
pct exec 107 -- bash -c '
  mkdir -p /opt/actions-runner && cd /opt/actions-runner
  RUNNER_VERSION=$(curl -sf https://api.github.com/repos/actions/runner/releases/latest | grep tag_name | cut -d\" -f4 | sed s/v//)
  curl -sL https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz | tar xz
'
```

## GitHub Actions Runner Setup

```bash
# SSH into the container
ssh root@172.16.10.249

# Configure the runner (get token from GitHub repo settings → Actions → Runners)
cd /opt/actions-runner
./config.sh --url https://github.com/greenautarky/ha-operating-system --token <TOKEN>

# Install and start as service
./svc.sh install
./svc.sh start
./svc.sh status
```

Then update the workflow:
```yaml
# .github/workflows/build-os.yml
runs-on: self-hosted
```

## Clone and Build

```bash
# SSH into container
ssh root@172.16.10.249

# Clone repo
git clone https://github.com/greenautarky/ha-operating-system.git /build
cd /build
git submodule update --init

# Build
./scripts/ga_build.sh dev    # dev build (~60 min)
./scripts/ga_build.sh prod   # prod build (~90 min)
```

## Secrets

These files must exist on the builder (gitignored, manually copied):

| File | Purpose |
|------|---------|
| `secrets/wifi-install.psk` | GreenAutarky-Install WiFi PSK |
| `secrets/openstick-wifi.key` | HMAC shared secret for OpenStick WiFi PSK derivation |
| `scripts/local.env` | Root password hash for device provisioning |
| `buildroot-external/ota/rel-ca.pem` | RAUC OTA signing CA certificate |
| `buildroot-external/ota/dev-ca.pem` | Symlink → `rel-ca.pem` |

In CI, these are injected from GitHub Secrets (see `.github/workflows/build-os.yml`).

## Build Cache

The container preserves build output between runs — incremental builds
are much faster (~15 min vs 90 min) because the toolchain and packages
are cached in `/build/ga_output/`.

To clean and rebuild from scratch:
```bash
rm -rf /build/ga_output
./scripts/ga_build.sh full prod
```

## Container Management

```bash
# From Proxmox host:
pct start 107
pct stop 107
pct restart 107
pct enter 107          # get a shell
pct exec 107 -- <cmd>  # run a command

# Snapshot (before risky changes):
pct snapshot 107 pre-update --description "Before system update"
pct rollback 107 pre-update

# Resize disk (if needed):
pct resize 107 rootfs +50G
```

## Monitoring

```bash
# From Proxmox host:
pct status 107
pct exec 107 -- df -h /
pct exec 107 -- free -h
pct exec 107 -- docker ps
```
