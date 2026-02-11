# Network Connectivity Ping Tests

## Component
Telegraf `inputs.ping` plugin (native ICMP method), gateway auto-detection

## Prerequisites
- Telegraf running with `inputs.ping` configured
- Network connectivity (LAN + internet)
- `/mnt/data/telegraf/env` contains `GATEWAY_IP`

## Tests

### PING-01: Gateway auto-detection
- **Action**: Verify gateway IP is detected and written to env file
- **Command**: `grep GATEWAY_IP /mnt/data/telegraf/env`
- **Expected**: Valid IP address (e.g., `GATEWAY_IP=192.168.31.1`), not `unknown`

### PING-02: Telegraf ping plugin loaded
- **Action**: Check telegraf logs for ping plugin initialization
- **Command**: `journalctl -u telegraf | grep -i ping`
- **Expected**: No errors, plugin loaded successfully

### PING-03: Gateway ping succeeds
- **Action**: Verify ping metrics for gateway IP
- **Command**: `telegraf --config /etc/telegraf/telegraf.conf --input-filter ping --test 2>&1 | grep result_code`
- **Expected**: `result_code=0` for gateway IP

### PING-04: Internet ping succeeds (1.1.1.1)
- **Action**: Verify ping metrics for Cloudflare DNS
- **Command**: Same as PING-03, filter for `url=1.1.1.1`
- **Expected**: `result_code=0`, `average_response_ms` > 0

### PING-05: Internet ping succeeds (8.8.8.8)
- **Action**: Verify ping metrics for Google DNS
- **Command**: Same as PING-03, filter for `url=8.8.8.8`
- **Expected**: `result_code=0`, `average_response_ms` > 0

### PING-06: Native method used (not exec)
- **Action**: Verify native ICMP sockets used, not BusyBox ping
- **Command**: `grep 'method.*native' /etc/telegraf/telegraf.conf`
- **Expected**: `method = "native"` present in config

### PING-07: Data reaches InfluxDB
- **Action**: Query InfluxDB for ping measurements
- **Command**: `influx -database device_metrics -execute "SELECT count(*) FROM ping WHERE time > now() - 5m"`
- **Expected**: Non-zero count for all 3 URLs
