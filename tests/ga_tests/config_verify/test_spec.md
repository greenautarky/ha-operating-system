# Config Deployment Verification Tests

## Purpose
Verify that critical configuration files were correctly deployed to the rootfs
and contain expected content. Catches stale configs from failed builds, missed
package updates, or RAUC OTA issues where new rootfs doesn't contain latest changes.

## Prerequisites
- Device booted with current rootfs (post-build or post-OTA)
- Services installed (telegraf, fluent-bit)
- Test harness available (`lib/test_helpers.sh`)

## Tests

### CFG-01: telegraf.conf exists on rootfs
- **Command**: `test -f /etc/telegraf/telegraf.conf`
- **Expected**: File exists (installed by telegraf package)

### CFG-02: telegraf.conf has device_label global tag
- **Command**: `grep -q 'device_label' /etc/telegraf/telegraf.conf`
- **Expected**: Config includes `device_label = "${DEVICE_LABEL}"`
- **Catches**: Stale config from pre-DEVICE_LABEL build

### CFG-03: telegraf.conf has uuid global tag
- **Command**: `grep -q 'uuid.*DEVICE_UUID' /etc/telegraf/telegraf.conf`
- **Expected**: Config includes `uuid = "${DEVICE_UUID}"`
- **Catches**: Stale config from pre-UUID build

### CFG-04: telegraf.service has DEVICE_LABEL ExecStartPre
- **Command**: `systemctl cat telegraf | grep -q 'DEVICE_LABEL.*ga-device-label'`
- **Expected**: Service extracts label from `/mnt/data/ga-device-label`

### CFG-05: telegraf.service has DEVICE_UUID ExecStartPre
- **Command**: `systemctl cat telegraf | grep -q 'DEVICE_UUID.*core.uuid'`
- **Expected**: Service extracts UUID from HA core.uuid

### CFG-06: telegraf.service has DEVICE_LABEL safe default
- **Command**: `systemctl cat telegraf | grep -q 'Environment=.*DEVICE_LABEL=unknown'`
- **Expected**: Fallback value present for first-boot safety

### CFG-07: fluent-bit.conf exists on rootfs
- **Command**: `test -f /etc/fluent-bit/fluent-bit.conf`
- **Expected**: File exists (installed by fluent-bit-config package)

### CFG-08: fluent-bit.conf has device_label in record_modifier filter
- **Command**: `grep -q 'device_label' /etc/fluent-bit/fluent-bit.conf`
- **Expected**: Filter adds `device_label` record to all log entries

### CFG-09: fluent-bit.conf has device_label in Loki output labels
- **Command**: `grep 'labels.*job=ihost' /etc/fluent-bit/fluent-bit.conf | grep -q 'device_label'`
- **Expected**: Loki labels include `device_label` for log identification

### CFG-10: fluent-bit.service has DEVICE_LABEL ExecStartPre
- **Command**: `systemctl cat fluent-bit | grep -q 'DEVICE_LABEL.*ga-device-label'`
- **Expected**: Service extracts label from `/mnt/data/ga-device-label`

### CFG-11: fluent-bit.service has DEVICE_LABEL safe default
- **Command**: `systemctl cat fluent-bit | grep -q 'Environment=.*DEVICE_LABEL=unknown'`
- **Expected**: Fallback value present for first-boot safety

### CFG-13: /etc/hosts has influx fallback entry
- **Command**: `grep -q 'influx.greenautarky.com' /etc/hosts`
- **Expected**: Static fallback entry exists for when NetBird DNS is unavailable
- **Catches**: Missing /etc/hosts after rootfs update

### CFG-14: /etc/hosts has loki fallback entry
- **Command**: `grep -q 'loki.greenautarky.com' /etc/hosts`
- **Expected**: Static fallback entry exists for Loki endpoint

### CFG-15: telegraf.service ordered after netbird
- **Command**: `systemctl cat telegraf | grep -q 'After=.*netbird.service'`
- **Expected**: Telegraf waits for NetBird VPN + DNS before starting
- **Catches**: Stale service file without NetBird ordering

### CFG-16: fluent-bit.service ordered after netbird
- **Command**: `systemctl cat fluent-bit | grep -q 'After=.*netbird.service'`
- **Expected**: Fluent-bit waits for NetBird VPN + DNS before starting

### CFG-17: influx.greenautarky.com resolves
- **Command**: `getent hosts influx.greenautarky.com`
- **Expected**: Hostname resolves via NetBird DNS or /etc/hosts fallback
- **Catches**: Both DNS and fallback broken

### CFG-18: loki.greenautarky.com resolves
- **Command**: `getent hosts loki.greenautarky.com`
- **Expected**: Hostname resolves via NetBird DNS or /etc/hosts fallback

### CFG-12: ga-device-label readable or fallback works
- **Action**: Check if device label file exists; if not, verify env falls back to "unknown"
- **Expected**: Either label file present with valid content, or env shows `DEVICE_LABEL=unknown`
