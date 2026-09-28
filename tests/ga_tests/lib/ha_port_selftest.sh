#!/bin/sh
# ha_port_selftest.sh — the port rule in lib/ha_port.sh, over canned
# `ha core info --raw-json` answers. Host-side (sh; jq optional — both parse
# paths are run). CI: lint.yml host-suites. Sources the LIVE helper.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/ha_port.sh" ] || { echo "FAIL: $HERE/ha_port.sh not found"; exit 1; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

n=0; bad=0
check() {  # <label> <want> <got>
  n=$((n+1))
  if [ "$2" = "$3" ]; then printf '  ok    %-52s %s\n' "$1" "$3"
  else printf '  WRONG %-52s got [%s] want [%s]\n' "$1" "$3" "$2"; bad=$((bad+1)); fi
}

info() {  # <file> <json data object>
  printf '{"result":"ok","data":%s}\n' "$2" > "$WORK/$1.json"
}
info new-80        '{"version":"2026.8.2","version_latest":"2026.9.1","port":80,"ssl":false}'
info old-8123      '{"version":"2025.11.5","version_latest":"2025.11.5","port":8123,"ssl":false}'
info new-noport    '{"version":"2026.8.2","version_latest":"2026.8.2","port":null}'
info beta-noport   '{"version":"2026.10.0b1","port":null}'
info dev-noport    '{"version":"2026.9.0.dev20260901","port":null}'
info next-year     '{"version":"2027.1.0","port":null}'
info old-noport    '{"version":"2025.11.5","port":null}'
info last-old      '{"version":"2026.7.4","port":null}'
info nothing       '{"version":null,"port":null}'
info landingpage   '{"version":"landingpage","port":null}'
info custom-port   '{"version":"2026.8.2","port":8443}'
: > "$WORK/empty.json"

resolve() {  # <fixture> [jq|nojq] -> "port source" or "ERR"
  (
    unset GA_HA_PORT GA_HA_PORT_SOURCE GA_HA_CORE_VERSION
    if [ "${2:-jq}" = nojq ]; then
      # Hide jq: a PATH holding only the tools the sed path needs.
      mkdir -p "$WORK/bin"
      for t in cat sed tr head cut printf; do
        p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$WORK/bin/$t"
      done
      PATH="$WORK/bin"
    fi
    . "$HERE/ha_port.sh"
    GA_HA_INFO_CMD="cat '$WORK/$1.json'"
    if _ga_ha_port_resolve 2>"$WORK/err"; then echo "$GA_HA_PORT $GA_HA_PORT_SOURCE"; else echo ERR; fi
  )
}

echo "=== ha_port selftest ==="
for mode in jq nojq; do
  if [ "$mode" = jq ] && ! command -v jq >/dev/null 2>&1; then
    echo "  (jq not installed — jq path not exercised)"; continue
  fi
  echo "  -- parse path: $mode"
  check "$mode: Supervisor says 80 (Core 2026.8.2)"  "80 supervisor"   "$(resolve new-80 $mode)"
  check "$mode: Supervisor says 8123 (Core 2025.11)" "8123 supervisor" "$(resolve old-8123 $mode)"
  check "$mode: Supervisor says 8443 — believed"     "8443 supervisor" "$(resolve custom-port $mode)"
  check "$mode: no port, Core 2026.8.2 -> 80"        "80 default-for-core-2026.8.2" "$(resolve new-noport $mode)"
  check "$mode: no port, Core 2026.10.0b1 -> 80"     "80 default-for-core-2026.10.0b1" "$(resolve beta-noport $mode)"
  check "$mode: no port, Core 2026.9 dev -> 80"      "80 default-for-core-2026.9.0.dev20260901" "$(resolve dev-noport $mode)"
  check "$mode: no port, Core 2027.1.0 -> 80"        "80 default-for-core-2027.1.0" "$(resolve next-year $mode)"
  check "$mode: no port, Core 2025.11.5 -> 8123"     "8123 known-old-core-2025.11.5" "$(resolve old-noport $mode)"
  check "$mode: no port, Core 2026.7.4 -> 8123"      "8123 known-old-core-2026.7.4" "$(resolve last-old $mode)"
  check "$mode: no port, no version -> refuse"       "ERR" "$(resolve nothing $mode)"
  check "$mode: no port, 'landingpage' -> refuse"    "ERR" "$(resolve landingpage $mode)"
  check "$mode: ha CLI answered nothing -> refuse"   "ERR" "$(resolve empty $mode)"
done

# The refusal names its reason.
( . "$HERE/ha_port.sh"; GA_HA_INFO_CMD="cat '$WORK/nothing.json'"; _ga_ha_port_resolve ) 2>"$WORK/why" >/dev/null
check "refusal says why on stderr" "yes" "$(grep -q 'Refusing to guess' "$WORK/why" && echo yes || echo no)"

# Resolved ONCE: a preset GA_HA_PORT is used and the CLI is not asked.
got=$( . "$HERE/ha_port.sh"; GA_HA_PORT=8123; GA_HA_INFO_CMD="echo ASKED >&2; cat '$WORK/new-80.json'"; ga_ha_port 2>&1 )
check "preset GA_HA_PORT wins, CLI not asked" "8123" "$got"
got=$( . "$HERE/ha_port.sh"; GA_HA_PORT=eighty; ga_ha_port 2>/dev/null || echo ERR )
check "preset GA_HA_PORT that is not a number -> refuse" "ERR" "$got"

# Exported for child suites.
got=$( . "$HERE/ha_port.sh"; unset GA_HA_PORT; GA_HA_INFO_CMD="cat '$WORK/new-80.json'"; _ga_ha_port_resolve; sh -c 'echo "$GA_HA_PORT"' )
check "resolved port is exported to a child shell" "80" "$got"

# internal_url suffix
got=$( . "$HERE/ha_port.sh"; printf '[%s][%s]' "$(ga_ha_url_port 80)" "$(ga_ha_url_port 8123)" )
check "url suffix: none on 80, :8123 otherwise" "[][:8123]" "$got"

echo "--- $n cases, $bad wrong ---"
[ "$n" -ge 20 ] || { echo "FAIL: only $n cases ran"; exit 1; }
[ "$bad" -eq 0 ]
