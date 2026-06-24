#!/bin/sh
# Edge-buffered telemetry test suite - runs ON the device.
# Verifies telegraf's durable disk store-and-forward + the ga_manager
# network-signal file-drop are live. The full outage+reboot back-fill proof is
# a semi-manual procedure — see test_spec.md (BUF-10..BUF-13).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Telemetry buffering (edge store-and-forward)"

METRICS_MARKER="/mnt/data/.ga-consent-metrics"
TG_CONF="/etc/telegraf/telegraf.conf"
[ -f /mnt/data/telegraf/override.conf ] && TG_CONF="/mnt/data/telegraf/override.conf"
BUF_DIR="/mnt/data/telegraf/buffer"
SIG_FILE="/mnt/data/supervisor/share/telegraf/ga-network.influx"

# Telegraf is Tier-2 / consent-gated — without consent these are correctly N/A.
if [ ! -f "$METRICS_MARKER" ]; then
  warn_test "BUF-00" "metrics consent NOT given — buffering suite N/A (expected)" "true"
  suite_end
  return 0 2>/dev/null || exit 0
fi

# BUF-01: active telegraf config declares the disk buffer
run_test "BUF-01" "disk buffer enabled (buffer_strategy=disk_write_through)" \
  "grep -q 'buffer_strategy *= *\"disk_write_through\"' $TG_CONF"

# BUF-02: buffer directory exists + is on /mnt/data (writable, not zram /tmp)
run_test "BUF-02" "buffer dir exists under /mnt/data" \
  "[ -d $BUF_DIR ]"

# BUF-03: telegraf loaded the file input for the ga_manager signal
run_test "BUF-03" "telegraf loaded the ga-network file input" \
  "journalctl -u telegraf --no-pager 2>/dev/null | grep -qiE 'Loaded inputs.*file' || grep -q 'ga-network.influx' $TG_CONF"

# BUF-04: cpu temperature input loaded
run_test "BUF-04" "telegraf loaded inputs.temp (cpu temperature)" \
  "journalctl -u telegraf --no-pager 2>/dev/null | grep -qiE 'Loaded inputs.*temp' || grep -q '\\[\\[inputs.temp\\]\\]' $TG_CONF"

# BUF-05: ga_manager is producing the signal file-drop (once it has an uplink)
if [ -f "$SIG_FILE" ]; then
  run_test "BUF-05" "ga_manager signal file present + has a network_signal point" \
    "grep -q '^network_signal,' $SIG_FILE"
else
  warn_test "BUF-05" "signal file not yet written (eth-only / no measurable uplink?)" "true"
fi

# BUF-06: no persistent telegraf output errors (buffer should be draining)
run_test "BUF-06" "no recent telegraf write/connection errors" \
  "! journalctl -u telegraf --since '-5min' --no-pager 2>/dev/null | grep -qiE 'failed to write|connection refused|could not write'"

# BUF-07: signal file write-rate is SD-friendly (write-on-change) — the file
# mtime should NOT advance on every poll when the signal is stable. Informational.
if [ -f "$SIG_FILE" ]; then
  warn_test "BUF-07" "signal file uses write-on-change (mtime stable when signal stable — inspect manually)" "true"
fi

suite_end
