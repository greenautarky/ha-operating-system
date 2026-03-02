# Tailscale Addon Tests

## Purpose
Verify that the ga_tailscale addon is running, connected, and configured
with the correct hostname matching the device label from provisioning.

## Prerequisites
- Device provisioned with QR code label (e.g., `KIB-SON-00000007`)
- ga_tailscale addon container running
- Tailscale authenticated and connected

## Tests

### TS-01: ga_tailscale addon container running
- **Command**: `docker ps --format '{{.Names}}' | grep -q 'ga_tailscale'`
- **Expected**: Container `addon_*_ga_tailscale` is running

### TS-02: Tailscale daemon is connected
- **Command**: `docker exec <container> /opt/tailscale status --json | grep -q '"Online":true'`
- **Expected**: Tailscale reports online status

### TS-03: Tailscale hostname matches device label
- **Command**: Compare `tailscale status --json` hostname with `/mnt/data/ga-device-label`
- **Expected**: Tailscale hostname equals device label (e.g., `KIB-SON-00000007`)
- **Catches**: Hostname persistence issue where addon overwrites provisioned hostname on restart

### TS-04: Tailscale has IP assigned
- **Command**: `docker exec <container> /opt/tailscale ip -4`
- **Expected**: Returns a 100.x.x.x Tailscale IP address

### TS-05: Tailscale uses greenautarky addon image (not upstream)
- **Command**: Check container image registry
- **Expected**: Image is `ghcr.io/greenautarky/ga_tailscale-*` (not `ghcr.io/hassio-addons/tailscale`)
- **Note**: Devices still on vibe_addons will fail — expected until migration
