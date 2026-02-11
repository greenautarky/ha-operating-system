# Network Configuration Tests

## Components
- Static DNS entries (`/etc/hosts`)
- NetBird VPN connectivity
- Service endpoint resolution

## Prerequisites
- Network interface configured (eth0/end0)
- NetBird installed and configured

## Tests

### NET-01: Static DNS entries present
- **Action**: Verify /etc/hosts contains GreenAutarky service entries
- **Command**: `grep greenautarky /etc/hosts`
- **Expected**: `influx.greenautarky.com` and `loki.greenautarky.com` resolve to `100.126.142.217`

### NET-02: InfluxDB endpoint reachable
- **Action**: Test TCP connectivity to InfluxDB
- **Command**: `nc -z -w5 influx.greenautarky.com 8086`
- **Expected**: Exit code 0 (connection successful)

### NET-03: Loki endpoint reachable
- **Action**: Test TCP connectivity to Loki
- **Command**: `nc -z -w5 loki.greenautarky.com 3100`
- **Expected**: Exit code 0 (connection successful)

### NET-04: Loki health check
- **Action**: Query Loki ready endpoint
- **Command**: `wget -qO- http://loki.greenautarky.com:3100/ready`
- **Expected**: Response contains "ready"

### NET-05: Default gateway detected
- **Action**: Verify default route exists
- **Command**: `ip route | grep "^default"`
- **Expected**: Non-empty output with gateway IP

### NET-06: Internet connectivity
- **Action**: Ping external DNS
- **Command**: `ping -c 1 -W 5 1.1.1.1`
- **Expected**: Exit code 0, 0% packet loss
