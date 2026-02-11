# Boot Timing Tests

## Components
- `/usr/libexec/ga-boot-timing` (metrics script, InfluxDB line protocol)
- Telegraf `inputs.exec` (calls script hourly, reports to InfluxDB)
- `systemd-analyze` + `systemctl show` (data sources)

## Prerequisites
- Device booted and telegraf running
- `systemd-analyze` available (part of systemd)

## Tests

### BOOT-01: Boot timing script exists and is executable
- **Action**: Verify script is installed on rootfs
- **Command**: `test -x /usr/libexec/ga-boot-timing && echo "OK"`
- **Expected**: `OK`

### BOOT-02: Script produces valid InfluxDB line protocol
- **Action**: Run script manually, verify output format
- **Command**: `/usr/libexec/ga-boot-timing`
- **Expected**: Single line starting with `boot_timing,boot_id=` followed by key=value fields
- **Example**: `boot_timing,boot_id=abc123 kernel=2.345,userspace=12.456,total=14.801,...`

### BOOT-03: Kernel and userspace times present
- **Action**: Verify systemd-analyze breakdown is captured
- **Command**: `/usr/libexec/ga-boot-timing | grep -oE 'kernel=[0-9.]+'`
- **Expected**: Non-empty output like `kernel=2.345`

### BOOT-04: Key service milestones present
- **Action**: Verify per-service timing fields
- **Command**: `/usr/libexec/ga-boot-timing`
- **Expected**: Output contains fields for:
  - `network_online` (network-online.target)
  - `docker` (docker.service)
  - `telegraf` (telegraf.service)
  - `crash_marker` (ga-crash-marker.service)
  - `multi_user` (multi-user.target)

### BOOT-05: Service times are plausible
- **Action**: Verify timing values make sense (ordered, reasonable range)
- **Command**: `/usr/libexec/ga-boot-timing`
- **Expected**:
  - `crash_marker` < `network_online` (crash detection starts early)
  - `network_online` < `docker` (network before containers)
  - All values > 0 and < 600 (under 10 minutes)

### BOOT-06: Telegraf exec input configured
- **Action**: Verify telegraf config includes boot timing exec
- **Command**: `grep -A3 "ga-boot-timing" /etc/telegraf/telegraf.conf`
- **Expected**: `inputs.exec` block with `/usr/libexec/ga-boot-timing` command

### BOOT-07: Boot timing data appears in telegraf output
- **Action**: Check telegraf logs for boot_timing measurement
- **Command**: `journalctl -u telegraf --since "2 hours ago" | grep boot_timing`
- **Expected**: At least one entry showing boot_timing metric was collected

### BOOT-08: Boot ID tag is unique per boot
- **Action**: Compare boot_id across two reboots
- **Command**: Query InfluxDB: `SELECT boot_id FROM boot_timing ORDER BY time DESC LIMIT 2`
- **Expected**: Two different boot_id values

### BOOT-09: Timing consistent after reboot
- **Action**: Reboot device, verify new timing data appears
- **Command**: After reboot: `/usr/libexec/ga-boot-timing`
- **Expected**: Fresh timing values (different boot_id, reasonable times)

### BOOT-10: Script handles missing services gracefully
- **Action**: Verify script doesn't error if a service doesn't exist
- **Command**: `/usr/libexec/ga-boot-timing 2>&1; echo "exit=$?"`
- **Expected**: `exit=0` (no errors, missing fields simply omitted)
