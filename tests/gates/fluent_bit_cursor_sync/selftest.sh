#!/usr/bin/env bash
# fluent_bit_cursor_sync/selftest.sh — no shipped journald input fsyncs its
# cursor per journal line.
#
# WHY
#   fluent-bit's systemd input saves its read cursor into its SQLite DB after
#   every collect round, and a round runs on every journal change from any
#   unit. Without `DB.Sync Off` SQLite runs synchronous=FULL, so each save
#   fsyncs: on a bench device (BOSv1.5.0-rc6, 2026-10-10) tier-0's cursor DBs
#   drove about two thirds of all SD-card writes. The fix is one line per
#   input, in two repositories (this one and ga-telemetry-config), and one
#   forgotten input brings the whole storm back. Hence a gate.
#
# WHAT IT CHECKS
#   Every fluent-bit config the image ships:
#     - buildroot-*/rootfs-overlay/etc/fluent-bit/**/*.conf  (OS entry points,
#       profile configs)
#     - buildroot-external/package/fluent-bit-config/*.conf  (tier-1)
#     - fluent-bit-tier0.conf from ga-telemetry-config at the version.yaml pin
#       (fetched from the public repo at that tag; TIER0_OVERLAY_CONF=<file>
#       overrides offline)
#   Rule: an [INPUT] with `Name systemd` and a `DB` must carry `DB.Sync Off`.
#   tail inputs are exempt: in_tail defaults to WAL + synchronous=normal and
#   only syncs at checkpoints.
#
# RED/GREEN IN THE TEST ITSELF
#   must-fail/*.conf must each be flagged, must-pass/*.conf must not. The
#   check runs the SAME function on fixtures and on the live configs, and
#   fails closed when the live scan finds no DB-backed systemd input at all.
#
# Exit 0 = green, 1 = a verdict failed, 2 = could not check (never green).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HERE="$ROOT/tests/gates/fluent_bit_cursor_sync"
VERSION_YAML="$ROOT/version.yaml"

die2() { echo "ERROR (could not check): $*" >&2; exit 2; }

W="$(mktemp -d "${TMPDIR:-/tmp}/fb-cursor-sync.XXXXXX")"
trap 'rm -rf "$W"' EXIT

# offenders <file> — prints "<file>: <tag>" per systemd input with a DB but
# without DB.Sync Off; prints "#DB <n>" with the number of DB-backed systemd
# inputs seen (for the fail-closed count).
offenders() {
  awk -v f="$1" '
    function flush() {
      if (sect == "[INPUT]" && name == "systemd" && db) {
        n++
        if (sync != "off") print f ": " (tag == "" ? "<untagged>" : tag)
      }
      name = ""; db = 0; sync = ""; tag = ""
    }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[[:space:]]*\[/ { flush(); sect = toupper($1); next }
    {
      k = tolower($1); v = tolower($2)
      if (k == "name") name = v
      else if (k == "db") db = 1
      else if (k == "db.sync") sync = v
      else if (k == "tag") tag = $2
    }
    END { flush(); print "#DB " n + 0 }
  ' "$1"
}

pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "  ok    $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }

echo "fixtures:"
nf=0
for f in "$HERE"/must-fail/*.conf; do
  [ -f "$f" ] || continue; nf=$((nf + 1))
  if offenders "$f" | grep -qv '^#DB'; then ok "must-fail $(basename "$f") flagged"
  else bad "must-fail $(basename "$f") NOT flagged"; fi
done
np=0
for f in "$HERE"/must-pass/*.conf; do
  [ -f "$f" ] || continue; np=$((np + 1))
  if offenders "$f" | grep -qv '^#DB'; then bad "must-pass $(basename "$f") flagged"
  else ok "must-pass $(basename "$f") clean"; fi
done
[ "$nf" -ge 1 ] && [ "$np" -ge 1 ] || die2 "fixture dirs empty (must-fail=$nf must-pass=$np)"

# --- the live configs -------------------------------------------------------
TC_VER="$(sed -n 's/^[[:space:]]*ga-telemetry-config:[[:space:]]*"\([^"]*\)".*/\1/p' "$VERSION_YAML")"
[ -n "$TC_VER" ] || die2 "no ga-telemetry-config pin in version.yaml"
if [ -n "${TIER0_OVERLAY_CONF:-}" ]; then
  cp "$TIER0_OVERLAY_CONF" "$W/fluent-bit-tier0.conf" || die2 "cannot read $TIER0_OVERLAY_CONF"
  comp_label="$TIER0_OVERLAY_CONF (override; pin is $TC_VER)"
else
  url="https://raw.githubusercontent.com/greenautarky/ga-telemetry-config/v${TC_VER}/src/ga-telemetry-config/etc/fluent-bit/fluent-bit-tier0.conf"
  curl -fsS --retry 3 --max-time 30 -o "$W/fluent-bit-tier0.conf" "$url" || die2 "cannot fetch $url"
  comp_label="ga-telemetry-config v$TC_VER"
fi

mapfile -t live < <(
  find "$ROOT"/buildroot-*/rootfs-overlay/etc/fluent-bit "$ROOT/buildroot-external/package/fluent-bit-config" \
    -name '*.conf' -type f 2>/dev/null | sort
)
[ "${#live[@]}" -ge 1 ] || die2 "no fluent-bit configs found in the tree"

echo "live (component: $comp_label):"
total=0
for f in "${live[@]}" "$W/fluent-bit-tier0.conf"; do
  out="$(offenders "$f")"
  n="$(printf '%s\n' "$out" | sed -n 's/^#DB //p')"
  total=$((total + n))
  label="${f#"$ROOT"/}"; [ "$f" = "$W/fluent-bit-tier0.conf" ] && label="fluent-bit-tier0.conf ($comp_label)"
  bad_lines="$(printf '%s\n' "$out" | grep -v '^#DB' || true)"
  if [ -n "$bad_lines" ]; then
    while IFS= read -r l; do bad "${l/#$f/$label} — systemd input with a cursor DB but without DB.Sync Off"; done <<< "$bad_lines"
  else
    ok "$label ($n DB-backed systemd inputs)"
  fi
done
[ "$total" -ge 1 ] || die2 "the live scan saw no DB-backed systemd input at all — parser or layout changed"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ] && { echo "PASS: no shipped journald cursor DB fsyncs per journal line"; exit 0; }
exit 1
