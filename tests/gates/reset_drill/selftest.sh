#!/usr/bin/env bash
# reset_drill/selftest.sh - the reset drill's VERDICT LOGIC goes red and green.
#
# The drill (tests/host_drills/reset_drill.sh) can only be run for real on a
# bench device. This proves, on the host, that each of its assertions fires on
# the defect it exists for and stays quiet on a healthy device - so that when
# it runs on K31 a green means something and a red points at one mechanism.
#
# WHAT RUNS: the LIVE drill script, unmodified. Only the TRANSPORT is replaced:
# `ssh` and `curl` are stubs that answer from a scenario directory (what the
# device would print), switching from the "before" to the "after" state once a
# trigger call (reset/reboot) is made. The device-side commands themselves are
# NOT exercised here (that is what the K31 run is for).
#
# Scenarios (expected failing assertions in brackets):
#   unclean-good               []
#   unclean-no-crash-entry     [a]        crash_history.log did not grow
#   unclean-no-journal-line    [b]        ga-boot-check logged nothing UNCLEAN
#   unclean-no-verdict         [c]        verdict file missing
#   unclean-empty-dump         [d]        dump exists but decodes to 0 bytes
#   unclean-no-dump            [d]        no dump at all although the image has the tool
#   unclean-telegraf-down      [e]        telegraf inactive
#   unclean-loki-missing       [f]        line never reached Loki
#   clean-good                 []         must-not-flag counterpart
#   clean-false-unclean        [a b c d]  clean reboot that WRONGLY looks unclean
#   unclean-no-marker          exit 2     precondition missing -> not a verdict
#   unclean-no-new-boot        exit 2     device never comes back with a new boot_id
#   plus: no confirm flag -> exit 2; Loki not configured -> (f) SKIP, not PASS.
# Exit 0 green, 1 a verdict failed, 2 could not check.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DRILL="${RESET_DRILL:-$ROOT/tests/host_drills/reset_drill.sh}"
[ -f "$DRILL" ] || { echo "ERROR (could not check): $DRILL not found" >&2; exit 2; }

W="$(mktemp -d "${TMPDIR:-/tmp}/reset-drill.XXXXXX")"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"

cat > "$W/bin/ssh" <<'EOF'
#!/bin/sh
# ssh stub: last argument is "# <name>\n<command>"; answer from $SCEN.
cmd=""; for a in "$@"; do cmd="$a"; done
name="$(printf '%s' "$cmd" | sed -n '1s/^# //p')"
case "$name" in trigger_*) touch "$SCEN/.after"; exit 0 ;; esac
# The label lives ONLY in /mnt/data/fluent-bit/env on a real device: answer it
# only if the drill reads that file (a drill reading another path gets nothing).
if [ "$name" = label ]; then
  case "$cmd" in */mnt/data/fluent-bit/env*) cat "$SCEN/before/label" 2>/dev/null ;; esac
  exit 0
fi
phase=before; [ -f "$SCEN/.after" ] && phase=after
if [ -f "$SCEN/$phase/$name" ]; then cat "$SCEN/$phase/$name"
elif [ -f "$SCEN/before/$name" ]; then cat "$SCEN/before/$name"
else exit 1; fi
EOF
cat > "$W/bin/curl" <<'EOF'
#!/bin/sh
# curl stub: Loki query_range answer
n="$(cat "$SCEN/loki_count" 2>/dev/null || echo 0)"
if [ "$n" -gt 0 ]; then echo '{"data":{"result":[{"values":[["1","UNCLEAN SHUTDOWN DETECTED"]]}]}}'
else echo '{"data":{"result":[]}}'; fi
EOF
chmod +x "$W/bin/ssh" "$W/bin/curl"

# mkscen <name> <mode> - a healthy device for that mode
mkscen() {
  local d="$W/$1"; mkdir -p "$d/before" "$d/after"
  local b="$d/before" a="$d/after"
  echo OK > "$b/ping"
  echo aaaaaaaa-0000 > "$b/boot_id";  echo bbbbbbbb-1111 > "$a/boot_id"
  echo 10 > "$b/crash_count"
  echo MARKER > "$b/marker"
  echo 1700000000 > "$b/epoch"
  echo K31-FIXTURE > "$b/label"
  echo yes > "$b/has_dump"
  echo active > "$b/tier1"
  echo inactive > "$b/bootcheck_state"
  echo active > "$a/telegraf"
  echo yes > "$a/consent_metrics"
  echo yes > "$a/consent_logs"
  if [ "$2" = unclean ]; then
    echo 11 > "$a/crash_count"
    echo "Nov 04 ga-boot-check[1]: <4>WARNING: UNCLEAN SHUTDOWN DETECTED - previous boot did not complete cleanly" > "$a/bootcheck_journal"
    echo present > "$a/verdict"
    echo /mnt/data/journal-dump/dump-20261104T100000-bbbbbbbb-bootcheck-unclean.log.gz > "$a/dump_list"
    echo 4096 > "$a/dump_read"
    echo 1 > "$d/loki_count"
  else
    echo 10 > "$a/crash_count"
    echo "Nov 04 ga-boot-check[1]: Clean boot - previous shutdown was graceful" > "$a/bootcheck_journal"
    echo absent > "$a/verdict"
    : > "$a/dump_list"
    echo 0 > "$d/loki_count"
  fi
}

# expected <scenario> <exit> <failing letters>  (letters "" = none)
PASS=0 FAIL=0
okk() { PASS=$((PASS + 1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }

run() {  # run <scenario> <mode> [extra env...] -> $W/out.<scenario>, rc in $W/rc.<scenario>
  local s="$1" m="$2"; shift 2
  env -i PATH="$W/bin:/usr/bin:/bin" SCEN="$W/$s" POLL=1 TRIGGER_WAIT=1 BOOT_TIMEOUT=4 SETTLE_TIMEOUT=2 \
      CLEAN_LOKI_WAIT=0 LOKI_WAIT_MIN=0 LOKI_QUERY_URL=http://loki.invalid "$@" \
      bash "$DRILL" --ssh root@fixture --mode "$m" --i-know-this-reboots-the-device > "$W/out.$s" 2>&1
  echo $? > "$W/rc.$s"
}

check() {  # check <scenario> <expected rc> <expected failing letters>
  local s="$1" erc="$2" want="$3" rc got
  rc="$(cat "$W/rc.$s")"
  got="$(grep -E '^  FAIL  \(' "$W/out.$s" | sed -E 's/^  FAIL  \(([a-f])\).*/\1/' | tr -d '\n')"
  if [ "$rc" = "$erc" ] && [ "$got" = "$want" ]; then okk "$s: rc=$rc failing=[${got}]"
  else bad "$s: rc=$rc (want $erc) failing=[${got}] (want [${want}])"; sed 's/^/        | /' "$W/out.$s" | tail -12; fi
}

echo "scenarios (the LIVE drill, stubbed transport):"
mkscen unclean-good unclean;                run unclean-good unclean;               check unclean-good 0 ""

mkscen unclean-no-crash-entry unclean; echo 10 > "$W/unclean-no-crash-entry/after/crash_count"
run unclean-no-crash-entry unclean;         check unclean-no-crash-entry 1 "a"

mkscen unclean-no-journal-line unclean; echo "nothing here" > "$W/unclean-no-journal-line/after/bootcheck_journal"
run unclean-no-journal-line unclean;        check unclean-no-journal-line 1 "b"

mkscen unclean-no-verdict unclean; echo absent > "$W/unclean-no-verdict/after/verdict"
run unclean-no-verdict unclean;             check unclean-no-verdict 1 "c"

mkscen unclean-empty-dump unclean; echo 0 > "$W/unclean-empty-dump/after/dump_read"
run unclean-empty-dump unclean;             check unclean-empty-dump 1 "d"

mkscen unclean-no-dump unclean; : > "$W/unclean-no-dump/after/dump_list"
run unclean-no-dump unclean;                check unclean-no-dump 1 "d"

mkscen unclean-telegraf-down unclean; echo inactive > "$W/unclean-telegraf-down/after/telegraf"
run unclean-telegraf-down unclean;          check unclean-telegraf-down 1 "e"
grep -q '\[owner: telegraf WAL\]' "$W/out.unclean-telegraf-down" && okk "(e) failure is labelled with its owner" || bad "(e) failure carries no owner label"

# consent matrix for (e): no consent -> SKIP; no consent + --require-consent -> FAIL;
# consent + telegraf inactive -> FAIL (above); consent + active -> PASS (unclean-good)
mkscen unclean-no-metrics-consent unclean
echo no > "$W/unclean-no-metrics-consent/after/consent_metrics"; echo inactive > "$W/unclean-no-metrics-consent/after/telegraf"
run unclean-no-metrics-consent unclean;     check unclean-no-metrics-consent 0 ""
grep -q '^  SKIP  (e) NOT COVERED: no metrics consent' "$W/out.unclean-no-metrics-consent" && okk "(e) without metrics consent is SKIP, not FAIL" || bad "(e) without metrics consent is not reported as SKIP"
cp -r "$W/unclean-no-metrics-consent" "$W/unclean-no-metrics-consent-req"; rm -f "$W/unclean-no-metrics-consent-req/.after"
run unclean-no-metrics-consent-req unclean REQUIRE_CONSENT=1; check unclean-no-metrics-consent-req 1 "e"
mkscen unclean-good-req unclean; run unclean-good-req unclean REQUIRE_CONSENT=1; check unclean-good-req 0 ""

# consent matrix for (f): no log consent -> SKIP; + --require-consent -> FAIL
mkscen unclean-no-logs-consent unclean; echo no > "$W/unclean-no-logs-consent/after/consent_logs"
run unclean-no-logs-consent unclean;        check unclean-no-logs-consent 0 ""
cp -r "$W/unclean-no-logs-consent" "$W/unclean-no-logs-consent-req"; rm -f "$W/unclean-no-logs-consent-req/.after"
run unclean-no-logs-consent-req unclean REQUIRE_CONSENT=1; check unclean-no-logs-consent-req 1 "f"
# --require-consent also forbids skipping (f) for an unset LOKI_QUERY_URL
mkscen unclean-no-loki-req unclean; run unclean-no-loki-req unclean LOKI_QUERY_URL= REQUIRE_CONSENT=1; check unclean-no-loki-req 1 "f"

# label: log consent but DEVICE_LABEL missing in /mnt/data/fluent-bit/env -> FAIL naming the path, never SKIP
mkscen unclean-no-label unclean; rm "$W/unclean-no-label/before/label"
run unclean-no-label unclean;               check unclean-no-label 1 "f"
grep -q 'DEVICE_LABEL missing in /mnt/data/fluent-bit/env' "$W/out.unclean-no-label" && okk "(f) missing label FAILs and names the file" || bad "(f) missing label not reported with its path"

mkscen unclean-loki-missing unclean; echo 0 > "$W/unclean-loki-missing/loki_count"
run unclean-loki-missing unclean;           check unclean-loki-missing 1 "f"

mkscen clean-good clean;                    run clean-good clean;                   check clean-good 0 ""

mkscen clean-false-unclean clean
echo 11 > "$W/clean-false-unclean/after/crash_count"
echo "ga-boot-check[1]: <4>WARNING: UNCLEAN SHUTDOWN DETECTED" > "$W/clean-false-unclean/after/bootcheck_journal"
echo present > "$W/clean-false-unclean/after/verdict"
echo /mnt/data/journal-dump/dump-20261104T100000-bbbbbbbb-bootcheck-unclean.log.gz > "$W/clean-false-unclean/after/dump_list"
echo 1 > "$W/clean-false-unclean/loki_count"
run clean-false-unclean clean;              check clean-false-unclean 1 "abcdf"

mkscen unclean-no-marker unclean; rm "$W/unclean-no-marker/before/marker"
run unclean-no-marker unclean;              check unclean-no-marker 2 ""

mkscen unclean-no-new-boot unclean; cp "$W/unclean-no-new-boot/before/boot_id" "$W/unclean-no-new-boot/after/boot_id"
run unclean-no-new-boot unclean;            check unclean-no-new-boot 2 ""

# (f) must be SKIP (not PASS) when Loki is not configured
mkscen unclean-no-loki unclean
run unclean-no-loki unclean LOKI_QUERY_URL=
if grep -q '^  SKIP  (f) NOT COVERED' "$W/out.unclean-no-loki" && ! grep -q '(f) .*queryable' "$W/out.unclean-no-loki"; then okk "unclean-no-loki: (f) is SKIP 'not covered', never PASS"
else bad "unclean-no-loki: (f) not reported as NOT COVERED"; fi

# the drill must refuse without the confirmation flag
env -i PATH="$W/bin:/usr/bin:/bin" SCEN="$W/unclean-good" bash "$DRILL" --ssh root@fixture --mode unclean > "$W/out.noconfirm" 2>&1; rc=$?
[ "$rc" = 2 ] && okk "refuses to reboot without --i-know-this-reboots-the-device (rc=2)" || bad "ran without the confirmation flag (rc=$rc)"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ] && { echo "PASS: the reset drill's assertions go red on each defect and green on a healthy device"; exit 0; }
exit 1
