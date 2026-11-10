#!/usr/bin/env bash
# Refuse the pre-18.x `hassos-*` systemd unit names in device-side files.
#
# HAOS 18.0 renamed its units hassos-* -> haos-* (haos-supervisor, haos-config,
# haos-agent, haos-apparmor, haos-data ...). Measured on a BOSv1.6 device (HAOS
# 18.3, Odoo #1738): only hassos-supervisor.service and hassos-config.service
# still resolve, and ONLY because an alias is shipped (symlink in /etc/systemd/
# system, Alias= in haos-config.service); hassos-agent / -apparmor / -data are
# "not-found". A unit that orders on or restarts a hassos-* name works today by
# the grace of an alias, and is a silent no-op (After=/Wants=) or a dropped
# start job (Requires=) the day the alias goes. BOSv1.6 is the only line on
# HAOS 18; the 1.5 line (HAOS 16) is another branch and is not checked here.
#
# Scope: device-side files of THIS tree (what lands on, or runs against, a
# device): buildroot-external, buildroot-ihost, tests/ga_tests. Not scanned:
# host tooling (scripts/, .github/), the gates themselves, CHANGELOG, docs.
# Partition labels (hassos-kernel0, hassos-data, ...) are not unit names and do
# not match; the pattern is the unit names plus any hassos-*.<unit suffix>.
#
# Fails closed: a missing scan root or zero files inspected is exit 2.
# Usage: check-haos-unit-names.sh [ROOT]   (default: the repo this script is in)
# Exit: 0 clean, 1 findings, 2 cannot judge.
set -uo pipefail
ROOT="$(cd "${1:-$(dirname "$0")/..}" && pwd)"
SCAN_DIRS=(buildroot-external buildroot-ihost tests/ga_tests)

UNIT_NAMES='supervisor|config|agent|apparmor|expand|persists|zram|swapfile|bt-cache|mglru|wipe|hardware|bind|docker-reset|user-rules|data-disk-detach'
PATTERN="hassos-(${UNIT_NAMES})|hassos-[A-Za-z0-9_.@-]*\\.(service|target|timer|socket|mount|path)"

# Allowlist: path (relative to ROOT) -> reason. Whole-file, so every entry must
# say why and tests/gates/haos_unit_names/selftest.sh fails an entry that no
# longer matches anything (a stale exemption is a hole).
ALLOW_PATHS=(
  # The alias symlink itself (-> haos-supervisor.service). Kept because
  # ga-bootstrap.service is synced from the sibling ga-bootstrap repo at build
  # time and still says Requires=hassos-supervisor.service; without the alias
  # its start job is dropped on every fresh device (SUP-11 class). Remove only
  # together with that unit's rename. Guarded by tests/gates/supervisor_alias.
  "buildroot-external/rootfs-overlay/etc/systemd/system/hassos-supervisor.service"
  # SUP-14b asserts on the device that the alias above LOADS; SUP-11/13 comments
  # document the history of the name. The test must name the old unit.
  "tests/ga_tests/supervisor_health/test.sh"
  # Build-test comments that document the alias and the 16.x -> 18.x rename
  # (TEL-BLD-06, UNITREF-01/02, HSUP, GAOS-07). No executable hassos-* unit
  # reference; GAOS-07's regex accepts the old spelling for the synced unit.
  "tests/ga_tests/run_build_tests.sh"
)

for d in "${SCAN_DIRS[@]}"; do
  [ -d "$ROOT/$d" ] || { echo "FAIL(2): scan root missing: $d (under $ROOT)"; exit 2; }
done

allowed() { local p; for p in "${ALLOW_PATHS[@]}"; do [ "$1" = "$p" ] && return 0; done; return 1; }

if [ "${HAOS_UNIT_NAMES_PRINT_ALLOW:-0}" = 1 ]; then printf '%s\n' "${ALLOW_PATHS[@]}"; echo "PATTERN=$PATTERN"; exit 0; fi

inspected=0 findings=0
while IFS= read -r -d '' f; do
  rel="${f#"$ROOT"/}"
  inspected=$((inspected+1))
  allowed "$rel" && continue
  base="${rel##*/}"
  if [[ "$base" =~ ^hassos-.*\.(service|target|timer|socket|mount|path)$ ]]; then
    echo "FINDING: $rel: file is named with the pre-18.x unit prefix (use haos-)"; findings=$((findings+1))
  fi
  [ -L "$f" ] && continue
  while IFS= read -r line; do
    echo "FINDING: $rel:$line"; findings=$((findings+1))
  done < <(grep -InE -- "$PATTERN" "$f" 2>/dev/null | cut -c1-200)
done < <(find "${SCAN_DIRS[@]/#/$ROOT/}" \( -type f -o -type l \) -print0)

if [ "$inspected" -eq 0 ]; then echo "FAIL(2): zero files inspected under ${SCAN_DIRS[*]}"; exit 2; fi
if [ "$findings" -gt 0 ]; then
  echo "FAIL: $findings hassos-* unit reference(s) in device-side files ($inspected files inspected). HAOS 18 names them haos-*; see header."
  exit 1
fi
echo "ok: no hassos-* unit references in $inspected device-side files"
