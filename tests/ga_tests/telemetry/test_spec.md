# Telemetry Services Tests

## Components
- Telegraf (metrics → InfluxDB)
- Fluent-Bit (logs → Loki)
- Environment system (`ga-env.conf`, env files)

## Prerequisites
- Both services installed and enabled
- InfluxDB reachable at `influx.greenautarky.com:8086`
- Loki reachable at `loki.greenautarky.com:3100`
- Home Assistant running (for UUID extraction)

## Tests

### TEL-01: Telegraf service running
- **Action**: Check telegraf systemd unit status
- **Command**: `systemctl is-active telegraf`
- **Expected**: `active`

### TEL-02: Fluent-Bit service running
- **Action**: Check fluent-bit systemd unit status
- **Command**: `systemctl is-active fluent-bit`
- **Expected**: `active`

### TEL-03: GA_ENV set in telegraf env file
- **Action**: Verify GA_ENV is populated
- **Command**: `grep GA_ENV /mnt/data/telegraf/env`
- **Expected**: `GA_ENV=dev` or `GA_ENV=prod` (not empty)

### TEL-04: GA_ENV set in fluent-bit env file
- **Action**: Verify GA_ENV is populated
- **Command**: `grep GA_ENV /mnt/data/fluent-bit/env`
- **Expected**: `GA_ENV=dev` or `GA_ENV=prod` (not empty)

### TEL-05: DEVICE_UUID extracted correctly
- **Action**: Verify UUID is a valid format (not "unknown")
- **Command**: `grep DEVICE_UUID /mnt/data/telegraf/env`
- **Expected**: UUID format `[0-9a-f]{8}-[0-9a-f]{4}-...-[0-9a-f]{12}`

### TEL-06: DEVICE_UUID matches across services
- **Action**: Compare UUID in telegraf and fluent-bit env files
- **Command**: `diff <(grep DEVICE_UUID /mnt/data/telegraf/env) <(grep DEVICE_UUID /mnt/data/fluent-bit/env)`
- **Expected**: Identical UUID values

### TEL-07: Telegraf config uses rootfs (OTA-updatable)
- **Action**: Verify telegraf runs from /etc/, not /mnt/data/
- **Command**: `systemctl cat telegraf | grep ExecStart`
- **Expected**: `--config /etc/telegraf/telegraf.conf`

### TEL-08: Fluent-Bit config uses rootfs (OTA-updatable)
- **Action**: Verify fluent-bit runs from /etc/, not /mnt/data/
- **Command**: `systemctl cat fluent-bit | grep ExecStart`
- **Expected**: `-c /etc/fluent-bit/fluent-bit.conf`

### TEL-09: Telegraf writes metrics to InfluxDB
- **Action**: Check telegraf logs for successful writes
- **Command**: `journalctl -u telegraf --since "5 min ago" | grep -i "wrote\|output"`
- **Expected**: No persistent write errors

### TEL-10: Fluent-Bit sends logs to Loki
- **Action**: Check fluent-bit logs for successful output
- **Command**: `journalctl -u fluent-bit --since "5 min ago" | grep -i "error\|loki"`
- **Expected**: No persistent connection errors

### TEL-11: Safe defaults prevent crash on first boot
- **Action**: Verify Environment= defaults are set in service files
- **Command**: `systemctl cat telegraf | grep "^Environment="`
- **Expected**: Contains `GA_ENV=dev DEVICE_UUID=unknown`

### TEL-12: ga-env.conf override works
- **Action**: Write override to /mnt/data/ga-env.conf, restart service, verify
- **Command**: `echo "GA_ENV=test" > /mnt/data/ga-env.conf && systemctl restart telegraf && grep GA_ENV /mnt/data/telegraf/env`
- **Expected**: `GA_ENV=test`
- **Cleanup**: Remove override file, restart service
