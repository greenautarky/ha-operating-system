# Watchdog Tests

## Component
Hardware watchdog (`/dev/watchdog`), `ga_test_wdt` helper

## Prerequisites
- Device with hardware watchdog support
- `ga_test_wdt` installed at `/usr/sbin/ga_test_wdt`

## Tests

### WDT-01: Watchdog device exists
- **Action**: Check `/dev/watchdog` exists
- **Command**: `test -c /dev/watchdog`
- **Expected**: Exit code 0

### WDT-02: Watchdog timeout configured
- **Action**: Read watchdog timeout
- **Command**: `cat /sys/class/watchdog/watchdog0/timeout`
- **Expected**: Non-zero integer (default: 60)

### WDT-03: Watchdog triggers reboot on hang
- **Action**: Open watchdog, stop petting it
- **Command**: `ga_test_wdt --trigger`
- **Expected**: Device reboots within timeout period, crash_history.log gets new entry

### WDT-04: Watchdog does not trigger during normal operation
- **Action**: Monitor watchdog during 5-minute normal operation
- **Command**: `uptime` before and after sleep
- **Expected**: No unexpected reboots, uptime increases
