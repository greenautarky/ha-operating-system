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

# 3. Install build dependencies
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
