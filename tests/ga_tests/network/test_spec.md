# Network Configuration Tests

## Components
- Static DNS entries (`/etc/hosts`)
- Telegraf InfluxDB output
- Fluent-Bit Loki output
- Service endpoint delivery

## Prerequisites
- Network interface configured (eth0/end0)
- NetBird installed and configured
- Telegraf and Fluent-Bit running

## Tests

### NET-01: Static DNS entries present
- **Action**: Verify /etc/hosts contains GreenAutarky service entries
- **Command**: `grep greenautarky /etc/hosts`
- **Expected**: `influx.greenautarky.com` and `loki.greenautarky.com` entries present

### NET-01b: DNS entries (show)
- **Action**: Display DNS entries for review
- **Command**: `grep greenautarky /etc/hosts`

### NET-02: Telegraf InfluxDB output loaded and no write errors
- **Action**: Verify telegraf loaded influxdb output at startup and has no recent write failures
- **Command**: Check journal for 'Loaded outputs.*influxdb' + no 'failed to write|connection refused|timeout' in last 5min
- **Expected**: Output plugin loaded, no persistent errors
- **Note**: Telegraf runs silently on success — no "wrote batch" messages at info level

### NET-03: Fluent-Bit Loki output configured and delivering
- **Action**: Verify fluent-bit connected to Loki and has no recent delivery failures
- **Command**: Check journal for 'loki.greenautarky.com' + no 'no upstream connections|connection refused' in last 5min
- **Expected**: Loki endpoint referenced in logs, no persistent errors

### NET-04: Telemetry services active with no recent errors
- **Action**: Verify both telegraf and fluent-bit are active with no recent output/flush errors
- **Command**: `systemctl is-active` + check journal for no 'error.*output|failed to flush|connection refused' in last 5min
- **Expected**: Both services active, no persistent errors

### NET-05: Default gateway detected
- **Action**: Verify default route exists
- **Command**: `ip route | grep "^default"`
- **Expected**: Non-empty output with gateway IP

### NET-06: Internet connectivity
- **Action**: Ping external DNS (or check ARP table if ping binary is broken)
- **Command**: `ping -c 1 -W 5 1.1.1.1` or ARP table fallback
- **Expected**: Exit code 0 or gateway present in ARP table
- **Note**: BusyBox ping may be broken on minimal HAOS builds

### NET-GW: Default gateway (show)
- **Action**: Display default gateway IP for review
- **Command**: `ip route | grep '^default' | head -1 | awk '{print $3}'`
