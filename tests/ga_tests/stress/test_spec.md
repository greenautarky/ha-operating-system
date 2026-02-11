# Stress / Stability Tests

## Components
- `stress-ng` (installed via `BR2_PACKAGE_STRESS_NG=y`)
- System stability under load (CPU, memory, I/O, thermal)
- Service recovery after resource pressure

## Prerequisites
- Device with `stress-ng` installed (`which stress-ng`)
- SSH access for monitoring during tests
- Telegraf running (to observe metrics during stress)

## Tests

### STRESS-01: stress-ng is installed
- **Action**: Verify stress-ng binary is available
- **Command**: `stress-ng --version`
- **Expected**: Version string (e.g., `stress-ng, version 0.17.x`)

### STRESS-02: CPU stress — 100% all cores for 5 minutes
- **Action**: Max out all CPU cores, verify system stays responsive
- **Command**: `stress-ng --cpu 0 --cpu-method matrixprod --timeout 300 --metrics-brief`
- **Expected**:
  - stress-ng completes without errors
  - SSH session remains responsive during test
  - `systemctl is-active telegraf fluent-bit` returns `active` after test

### STRESS-03: Memory stress — 80% RAM for 5 minutes
- **Action**: Allocate and touch 80% of physical memory
- **Command**: `stress-ng --vm 2 --vm-bytes 80% --vm-method all --timeout 300 --metrics-brief`
- **Expected**:
  - Completes without OOM kill of critical services
  - `journalctl -b 0 | grep -i "oom\|killed"` — no HA/telegraf/fluent-bit killed

### STRESS-04: Disk I/O stress — sustained writes for 5 minutes
- **Action**: Heavy sequential + random I/O on data partition
- **Command**: `stress-ng --hdd 2 --hdd-bytes 256M --temp-path /mnt/data --timeout 300 --metrics-brief`
- **Expected**:
  - Completes without filesystem errors
  - `dmesg | grep -i "error\|fault"` — no new I/O errors
  - `/mnt/data` still writable after test

### STRESS-05: Combined stress — CPU + memory + I/O for 10 minutes
- **Action**: Simulate heavy workload across all subsystems
- **Command**:
  ```
  stress-ng --cpu 2 --vm 1 --vm-bytes 60% --hdd 1 --hdd-bytes 128M \
    --temp-path /mnt/data --timeout 600 --metrics-brief
  ```
- **Expected**:
  - System does not crash or reboot
  - All critical services survive: `systemctl is-active hassio-supervisor telegraf fluent-bit`
  - No unclean shutdown marker after next reboot

### STRESS-06: Thermal throttling under load
- **Action**: Monitor CPU temperature during sustained CPU stress
- **Command**:
  ```
  stress-ng --cpu 0 --timeout 300 &
  for i in $(seq 1 30); do
    cat /sys/class/thermal/thermal_zone0/temp
    sleep 10
  done
  kill %1
  ```
- **Expected**:
  - Temperature stays below critical threshold (typically < 85000 millidegrees)
  - If throttling occurs, system remains stable

### STRESS-07: Service recovery after OOM pressure
- **Action**: Push memory until OOM killer acts, verify services restart
- **Command**:
  ```
  stress-ng --vm 4 --vm-bytes 95% --timeout 60 2>/dev/null
  sleep 10
  systemctl is-active telegraf fluent-bit hassio-supervisor
  ```
- **Expected**:
  - Services restart automatically (systemd `Restart=always`)
  - `systemctl is-active` returns `active` for all critical services

### STRESS-08: Fork bomb resilience
- **Action**: Verify system handles process exhaustion gracefully
- **Command**: `stress-ng --fork 4 --timeout 60 --metrics-brief`
- **Expected**:
  - stress-ng completes or is killed by limits
  - System remains accessible via SSH
  - Critical services still running

### STRESS-09: Network stress under system load
- **Action**: Verify telemetry still flows during CPU stress
- **Command**:
  ```
  stress-ng --cpu 0 --timeout 120 &
  sleep 30
  journalctl -u telegraf --since "30 sec ago" | grep -i "error\|wrote"
  kill %1
  ```
- **Expected**: Telegraf continues writing metrics (no timeout errors)

### STRESS-10: Uptime stability — 24h soak test
- **Action**: Light continuous load for extended period
- **Command**: `stress-ng --cpu 1 --vm 1 --vm-bytes 30% --timeout 86400 --metrics-brief`
- **Expected**:
  - System runs for 24 hours without crash
  - `uptime` shows 24h+ after test
  - No entries in `/mnt/data/crash_history.log` during period
  - Telegraf/fluent-bit metrics flowing throughout
