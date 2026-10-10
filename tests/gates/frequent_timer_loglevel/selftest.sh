#!/usr/bin/env bash
# frequent_timer_loglevel/selftest.sh — a unit that runs every few minutes does
# not write its routine lines into the persistent journal.
#
# WHY
#   Each run of a timer-driven oneshot puts PID 1's "Starting" and
#   "Finished"/"Deactivated" lines plus the script's info output into the
#   journal on the SD card. On a bench device (BOSv1.5.0-rc6) that was ~10 % of
#   all journal entries (Odoo #1225); one unit ran every 30 s.
#
# RULE
#   Every .timer in the image that fires at least every 5 min
#   (OnUnitActiveSec <= 300 s) must either
#     - start a .service with LogLevelMax=notice (or stricter), or
#     - be listed in EXEMPT below with the reason it cannot be capped yet.
#   EXEMPT names must exist (a stale exemption is a failure, not a skip).
#
# RED/GREEN IN THE TEST ITSELF
#   The same check runs over fixtures/must-fail and fixtures/must-pass trees
#   before the live tree, and the live scan fails closed when it finds no
#   frequent timer at all.
#
# Exit 0 = green, 1 = a verdict failed, 2 = could not check.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HERE="$ROOT/tests/gates/frequent_timer_loglevel"

# unit -> why it is not capped (yet). These log their ACTIONS (or errors) as
# plain stdout, i.e. at info; a cap would silence real events. Make the script
# priority-aware first (<4>/<3> or logger -p), then cap it and drop it here.
declare -A EXEMPT=(
  [ga-disk-guard]="logs its cleanup actions as plain stdout (info)"
  [ga-openstick-autoconnect]="logs connect attempts and results as plain stdout (info)"
  [ga-resolve-ota]="logs endpoint changes and some errors as plain stdout (info)"
)

die2() { echo "ERROR (could not check): $*" >&2; exit 2; }

# secs <systemd time span> — 30, 30s, 2min, 5min, 300, 1h
secs() {
  local v="$1" n u
  n="${v%%[a-z]*}"; u="${v#"$n"}"
  [[ "$n" =~ ^[0-9]+$ ]] || { echo 999999; return; }
  case "$u" in
    ""|s|sec|secs) echo "$n" ;;
    m|min|mins) echo $((n * 60)) ;;
    h|hr|hour|hours) echo $((n * 3600)) ;;
    *) echo 999999 ;;
  esac
}

# check_tree <root> <exempt:yes|no> — prints one line per verdict:
#   "FREQ <timer>" for each frequent timer, "BAD <unit> <why>" per violation.
check_tree() {
  local root="$1" use_exempt="$2" t base iv svc f lvl skip='/nonexistent/*'
  # The live scan must not see this gate's own fixtures.
  [ "$use_exempt" = yes ] && skip="$root/tests/*"
  while IFS= read -r t; do
    base="$(basename "$t" .timer)"
    iv="$(sed -n 's/^OnUnitActiveSec=[[:space:]]*//p' "$t" | tail -1)"
    [ -n "$iv" ] || continue
    [ "$(secs "$iv")" -le 300 ] || continue
    echo "FREQ $base"
    svc="$(sed -n 's/^Unit=[[:space:]]*//p' "$t" | tail -1)"; svc="${svc:-$base.service}"
    f="$(find "$root" -path '*/rootfs-overlay/*' -name "$svc" -not -path '*.wants/*' -not -path "$skip" -type f | head -1)"
    if [ -z "$f" ]; then echo "BAD $base service $svc not found"; continue; fi
    lvl="$(sed -n 's/^LogLevelMax=[[:space:]]*//p' "$f" | tail -1)"
    case "$lvl" in
      emerg|alert|crit|err|warning|notice|[0-5]) ;;
      *)
        if [ "$use_exempt" = yes ] && [ -n "${EXEMPT[$base]:-}" ]; then echo "EXEMPT $base"
        else echo "BAD $base every $iv, LogLevelMax=${lvl:-<unset>}"; fi ;;
    esac
  done < <(find "$root" -path '*/rootfs-overlay/*' -name '*.timer' -not -path '*.wants/*' -not -path "$skip" -type f | sort)
}

pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "  ok    $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }

echo "fixtures:"
out="$(check_tree "$HERE/fixtures/must-fail" no)"
nbad="$(grep -c '^BAD' <<< "$out")"
nfreq="$(grep -c '^FREQ' <<< "$out")"
[ "$nfreq" -ge 1 ] || die2 "must-fail fixture tree has no frequent timer"
[ "$nbad" = "$nfreq" ] && ok "must-fail: all $nfreq frequent timers flagged" || bad "must-fail: $nbad of $nfreq flagged"
out="$(check_tree "$HERE/fixtures/must-pass" no)"
[ "$(grep -c '^FREQ' <<< "$out")" -ge 1 ] || die2 "must-pass fixture tree has no frequent timer"
grep -q '^BAD' <<< "$out" && bad "must-pass flagged: $(grep '^BAD' <<< "$out" | tr '\n' ';')" || ok "must-pass: nothing flagged (incl. a 10 min timer and a capped one)"

echo "live:"
out="$(check_tree "$ROOT" yes)"
nfreq="$(grep -c '^FREQ' <<< "$out")"
[ "$nfreq" -ge 1 ] || die2 "no frequent timer in the image tree — layout changed?"
while read -r k u rest; do
  case "$k" in
    BAD) bad "$u $rest" ;;
    EXEMPT) ok "$u exempt: ${EXEMPT[$u]}" ;;
  esac
done <<< "$out"
for u in "${!EXEMPT[@]}"; do
  grep -q "^FREQ $u\$" <<< "$out" || bad "stale exemption: $u is not a frequent timer in the image"
done
capped=$((nfreq - $(grep -c '^BAD' <<< "$out") - $(grep -c '^EXEMPT' <<< "$out")))
ok "$capped of $nfreq frequent timers capped at notice"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ] && { echo "PASS: frequent timers do not write routine lines into the journal"; exit 0; }
exit 1
