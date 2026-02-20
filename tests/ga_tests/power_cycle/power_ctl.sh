#!/usr/bin/env bash
# power_ctl.sh - Power control abstraction for power-cycle tests
#
# Provides power_off() and power_on() functions using one of:
#   1. REST API mode  (--power-api)  — host-power-service.py / uhubctl
#   2. Command mode   (--power-cmd-off/on) — Tasmota, GPIO relay, etc.
#   3. Manual mode    (fallback) — prompts user to physically toggle power
#
# Source this file from test.sh. Requires these variables to be set:
#   POWER_METHOD  — "api", "cmd", or "manual"
#   POWER_API     — REST API URL (api mode)
#   POWER_PORT    — port number for API (api mode)
#   POWER_CMD_OFF — shell command (cmd mode)
#   POWER_CMD_ON  — shell command (cmd mode)
#
# Custom command examples:
#   --power-cmd-off "curl -s 'http://tasmota.local/cm?cmnd=Power%20Off'"
#   --power-cmd-on  "curl -s 'http://tasmota.local/cm?cmnd=Power%20On'"
#   --power-cmd-off "ssh relay-host gpio-ctl off 3"
#   --power-cmd-on  "ssh relay-host gpio-ctl on 3"

power_off() {
    case "$POWER_METHOD" in
        api)
            local resp
            resp=$(curl -sf --max-time 10 -X POST "${POWER_API}/power/${POWER_PORT}/off" 2>&1) || {
                echo "  WARN: Power API off failed: $resp" >&2
                return 1
            }
            ;;
        cmd)
            eval "$POWER_CMD_OFF" || {
                echo "  WARN: Power off command failed" >&2
                return 1
            }
            ;;
        manual)
            echo "  >>> MANUAL: Power OFF the device, then press Enter"
            read -r
            ;;
        *)
            echo "  ERROR: Unknown power method: $POWER_METHOD" >&2
            return 1
            ;;
    esac
}

power_on() {
    case "$POWER_METHOD" in
        api)
            local resp
            resp=$(curl -sf --max-time 10 -X POST "${POWER_API}/power/${POWER_PORT}/on" 2>&1) || {
                echo "  WARN: Power API on failed: $resp" >&2
                return 1
            }
            ;;
        cmd)
            eval "$POWER_CMD_ON" || {
                echo "  WARN: Power on command failed" >&2
                return 1
            }
            ;;
        manual)
            echo "  >>> MANUAL: Power ON the device, then press Enter"
            read -r
            ;;
        *)
            echo "  ERROR: Unknown power method: $POWER_METHOD" >&2
            return 1
            ;;
    esac
}

# Determine power control method from configured variables
resolve_power_method() {
    if [[ -n "${POWER_API:-}" ]]; then
        POWER_METHOD="api"
        echo "Power control: REST API (${POWER_API}, port ${POWER_PORT})"
    elif [[ -n "${POWER_CMD_OFF:-}" && -n "${POWER_CMD_ON:-}" ]]; then
        POWER_METHOD="cmd"
        echo "Power control: Custom commands"
    else
        POWER_METHOD="manual"
        echo "Power control: MANUAL (will prompt for each cycle)"
        echo "  Tip: Set --power-api or --power-cmd-off/--power-cmd-on for automation"
    fi
}
