#!/bin/sh
# ga-addon-prime against BOTH `ha` CLI generations (Supervisor 2025.11.x and 2026.10+).
#
# Host-side suite: drives the REAL ga-addon-prime script (only its two device
# paths are redirected through the GA_PRIME_CONF / GA_PRIME_MARKER hooks) with a
# stub `docker` that plays hassio_cli:
#   old   CLI knows only `ha addons ...`; `ha apps` is "unknown command" (rc 1).
#   new   CLI has `ha apps ...`; `ha addons ...` works but prints
#         "The use of 'addons' is deprecated, please use 'apps' instead!" on STDERR.
#   help0 an old-style CLI that answers an unknown word with its root help, rc 0.
# The stub texts follow the real 2026.10 CLI: `ha apps --help` rc 0 listing
# "update"; `ha bogus --help` rc 1 "Error: unknown command ..."; errors on
# stderr, behind the notice.
#
#   APRIME-0x  generation detection and which word the update/start calls use
#   APRIME-1x  classification (primed / no-op / not installed / auth / real error)
#   APRIME-2x  the logged FAILED line carries the real error, never the notice;
#              the full output follows it
#
# Usage: test.sh [new|old]   (default: new = the live script)
#   old = RED PROOF: the script from $GA_PRIME_BASELINE_REF (a git ref that
#   still has the previous version; required), with only the two path hooks
#   substituted. It must FAIL the new-CLI cases and pass the old-CLI ones.
# Shell under test: GA_T_SHELL (default "sh"; CI also runs "busybox sh").
# Needs sh, coreutils, grep, sed. No device.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"
suite_start "ga-addon-prime on both ha CLI generations"

R="$SCRIPT_DIR/../../.."
LIVE="$R/buildroot-external/rootfs-overlay/usr/sbin/ga-addon-prime"
REL=buildroot-external/rootfs-overlay/usr/sbin/ga-addon-prime
MODE="${1:-new}"
SH="${GA_T_SHELL:-sh}"
W=${KEEPW:-$(mktemp -d)}; mkdir -p "$W"
mkdir -p "$W/bin"

case "$MODE" in
  new) SUT="$LIVE" ;;
  old)
    REF="${GA_PRIME_BASELINE_REF:?old mode needs GA_PRIME_BASELINE_REF (a git ref with the previous script)}"
    git -C "$R" show "$REF:$REL" > "$W/old-script" || { echo "cannot read $REF:$REL"; exit 2; }
    # The baseline already carries the two path hooks; copy it unchanged.
    cp "$W/old-script" "$W/sut"
    [ "$(grep -c 'GA_PRIME_CONF\|GA_PRIME_MARKER' "$W/sut")" -ge 2 ] || { echo "baseline path hooks missing"; exit 2; }
    SUT="$W/sut"; echo "RED PROOF: baseline $REF" ;;
  *) echo "mode: new | old"; exit 2 ;;
esac
run_test "APRIME-00" "script under test present and non-empty" "test -s '$SUT'"

# --- stub docker (plays hassio_cli) -------------------------------------------
cat > "$W/bin/docker" <<'STUB'
#!/bin/sh
[ "$1" = exec ] && [ "$2" = hassio_cli ] || exit 0
shift 2
[ "$1" = /bin/true ] && exit 0
[ "$1" = ha ] || exit 0
shift
echo "ha $*" >> "$STUB_CALLS"
GEN="${STUB_GEN:-new}"
NOTICE="The use of 'addons' is deprecated, please use 'apps' instead!"
unknown() { echo "Error: unknown command \"$1\" for \"ha\"" >&2; echo "Run 'ha --help' for usage." >&2; exit 1; }
apps_help() {
  printf '%s\n' 'The apps command allows you to manage Home Assistant apps.' '' 'Usage:' '  ha apps [flags]' '' \
    'Available Commands:' '  info        Show information' '  install     Installs an app' \
    '  start       Manually start a stopped app' '  update      Upgrades an app to the latest version'
  exit 0
}
apps_cmd() {  # apps_cmd <update|start> <slug>
  case "$1" in
    --help) apps_help ;;
    start) exit 0 ;;
    update)
      case "${STUB_SCEN:-ok}" in
        ok) exit 0 ;;
        noupdate) echo "Error: No update available for $2" >&2; exit 1 ;;
        missing) echo "Error: App $2 does not exist in the store" >&2; exit 1 ;;
        auth) echo "Error: Supervisor error: pull access denied for ghcr.io/greenautarky/x, repository does not exist or may require authorization" >&2; exit 1 ;;
        notready) # refused 3 times, then accepted (state: attempt counter file)
          _n=$(cat "$STUB_CALLS.n" 2>/dev/null || echo 0); _n=$((_n + 1)); echo "$_n" > "$STUB_CALLS.n"
          [ "$_n" -gt 3 ] && exit 0
          echo "Error: Supervisor is not ready to perform this operation, please try again later" >&2; exit 1 ;;
        notready_forever) echo "Error: Supervisor is not ready to perform this operation, please try again later" >&2; exit 1 ;;
        other) echo "Error: Can't update $2: image pull failed (no space left on device)" >&2; exit 1 ;;
      esac ;;
  esac
  exit 0
}
case "$1" in
  info)  # readiness: .data.state; STUB_STATE=startup stays there, STUB_STARTUP_N=n = startup for n calls
    _n=$(cat "$STUB_CALLS.i" 2>/dev/null || echo 0); _n=$((_n + 1)); echo "$_n" > "$STUB_CALLS.i"
    case "${STUB_INFO_BAD:-}" in rc1) echo "Error: boom" >&2; exit 1 ;; empty) exit 0 ;; garbage) echo "<html>not json"; exit 0 ;; esac
    _st="${STUB_STATE:-running}"
    [ -n "${STUB_STARTUP_N:-}" ] && { [ "$_n" -le "$STUB_STARTUP_N" ] && _st=startup || _st=running; }
    printf '{"result":"ok","data":{"state":"%s","version":"x"}}\n' "$_st"; exit 0 ;;
  store)  # a store call while Supervisor is not running is refused, as the real one is
    _s="${STUB_STATE:-running}"
    # startup phase counted in store calls too (the old probe never calls `info`): refuse the first STUB_STARTUP_N calls
    if [ -n "${STUB_STARTUP_N:-}" ] && [ ! -f "$STUB_CALLS.i" ]; then _k=$(cat "$STUB_CALLS.s" 2>/dev/null || echo 0); _k=$((_k + 1)); echo "$_k" > "$STUB_CALLS.s"; [ "$_k" -le "$STUB_STARTUP_N" ] && _s=startup; fi
    [ "$_s" = running ] || { echo "Error: System is not ready with state: $_s" >&2; exit 1; }
    [ "${STUB_STORE:-ok}" = fail ] && { echo "Error: store reload failed: HTTP 429" >&2; exit 1; }
    [ -n "${STUB_HANG:-}" ] && /bin/sleep 8
    exit 0 ;;
  docker) echo '{"data":{"registries":{}}}'; exit 0 ;;
  apps)
    case "$GEN" in
      new) shift; apps_cmd "$@" ;;
      old) unknown apps ;;
      help0) printf '%s\n' 'Usage:' '  ha [command]' 'Available Commands:' '  supervisor  Supervisor' '  addons      Add-ons'; exit 0 ;;
    esac ;;
  addons)
    shift
    case "$GEN" in
      new) [ "$1" = --help ] || echo "$NOTICE" >&2; apps_cmd "$@" ;;
      old|help0) apps_cmd "$@" ;;
    esac ;;
esac
exit 0
STUB
# Fake clock: `sleep N` advances $FAKE_CLOCK by N instead of waiting, and `date +%s`
# reports real time + that offset, so the script's deadline logic runs in milliseconds.
REAL_DATE="$(command -v date)"
cat > "$W/bin/sleep" <<'STUB'
#!/bin/sh
[ -n "${FAKE_CLOCK:-}" ] && echo $(( $(cat "$FAKE_CLOCK" 2>/dev/null || echo 0) + ${1:-0} )) > "$FAKE_CLOCK"
exit 0
STUB
cat > "$W/bin/date" <<STUB
#!/bin/sh
if [ "\$1" = +%s ]; then echo \$(( \$($REAL_DATE +%s) + \$(cat "\${FAKE_CLOCK:-/dev/null}" 2>/dev/null || echo 0) )); else exec $REAL_DATE "\$@"; fi
STUB
chmod +x "$W/bin/docker" "$W/bin/sleep" "$W/bin/date"
printf 'GA-FAKE_ga_manager\n' > "$W/prime.conf"

# prime <gen> <scenario> <name> — run the script; leaves $W/<name>.{log,rc,calls,marker}
prime() {
  rm -f "$W/$3.marker" "$W/$3.calls" "$W/$3.calls.n" "$W/$3.calls.i" "$W/$3.calls.s" "$W/$3.clock"; : > "$W/$3.calls"
  FAKE_CLOCK="$W/$3.clock" GA_PRIME_SH="$SH" PATH="$W/bin:$PATH" TMPDIR="$W" STUB_GEN="$1" STUB_SCEN="$2" STUB_CALLS="$W/$3.calls" \
    GA_PRIME_CONF="$W/prime.conf" GA_PRIME_MARKER="$W/$3.marker" \
    $SH "$SUT" > "$W/$3.log" 2>&1
  echo $? > "$W/$3.rc"
}
rc() { cat "$W/$1.rc"; }
called() { grep -qx "ha $2" "$W/$1.calls"; }

# --- APRIME-0x: detection and the word used ----------------------------------
prime old ok old_ok
prime new ok new_ok
prime help0 ok help0_ok
run_test "APRIME-01" "old CLI (2025.11.x): primes via 'ha addons update' + 'ha addons start', marker written, rc 0" \
  "[ \"\$(rc old_ok)\" = 0 ] && [ -f '$W/old_ok.marker' ] && grep -qx 'ha addons update GA-FAKE_ga_manager' '$W/old_ok.calls' && grep -qx 'ha addons start GA-FAKE_ga_manager' '$W/old_ok.calls'"
run_test "APRIME-02" "old CLI: 'ha apps update' is never issued" "! grep -q '^ha apps update' '$W/old_ok.calls'"
run_test "APRIME-03" "new CLI (2026.10+): primes via 'ha apps update' + 'ha apps start', marker written, rc 0" \
  "[ \"\$(rc new_ok)\" = 0 ] && [ -f '$W/new_ok.marker' ] && grep -qx 'ha apps update GA-FAKE_ga_manager' '$W/new_ok.calls' && grep -qx 'ha apps start GA-FAKE_ga_manager' '$W/new_ok.calls'"
run_test "APRIME-04" "new CLI: the deprecated 'ha addons update/start' is never issued" \
  "! grep -qE '^ha addons (update|start)' '$W/new_ok.calls'"
run_test "APRIME-05" "CLI that answers an unknown word with root help rc 0 is NOT taken for an apps CLI" \
  "[ \"\$(rc help0_ok)\" = 0 ] && grep -qx 'ha addons update GA-FAKE_ga_manager' '$W/help0_ok.calls' && ! grep -q '^ha apps update' '$W/help0_ok.calls'"
run_test "APRIME-06" "the log names the generation it chose" \
  "grep -q \"using 'ha addons'\" '$W/old_ok.log' && grep -q \"using 'ha apps'\" '$W/new_ok.log'"

# --- APRIME-1x: classification is the same on both generations ----------------
for g in old new; do
  prime $g noupdate ${g}_noupd; prime $g missing ${g}_miss; prime $g auth ${g}_auth; prime $g other ${g}_other
done
run_test "APRIME-10" "'No update available' = already pinned: rc 0, marker written (old and new CLI)" \
  "[ \"\$(rc old_noupd)\" = 0 ] && [ -f '$W/old_noupd.marker' ] && [ \"\$(rc new_noupd)\" = 0 ] && [ -f '$W/new_noupd.marker' ]"
run_test "APRIME-11" "'does not exist' = not installed yet: rc 0, NO marker, logged as skipped (old and new CLI)" \
  "[ \"\$(rc old_miss)\" = 0 ] && [ ! -f '$W/old_miss.marker' ] && [ \"\$(rc new_miss)\" = 0 ] && [ ! -f '$W/new_miss.marker' ] && grep -q 'not installed yet' '$W/new_miss.log' && grep -q 'not installed yet' '$W/old_miss.log'"
run_test "APRIME-12" "registry auth failure: rc 1, NO marker, classified as registry auth (old and new CLI)" \
  "[ \"\$(rc old_auth)\" = 1 ] && [ ! -f '$W/old_auth.marker' ] && [ \"\$(rc new_auth)\" = 1 ] && [ ! -f '$W/new_auth.marker' ] && grep -q 'FAILED (registry auth' '$W/new_auth.log' && grep -q 'FAILED (registry auth' '$W/old_auth.log'"
run_test "APRIME-13" "unclassified error: rc 1, NO marker (old and new CLI)" \
  "[ \"\$(rc old_other)\" = 1 ] && [ ! -f '$W/old_other.marker' ] && [ \"\$(rc new_other)\" = 1 ] && [ ! -f '$W/new_other.marker' ]"

# --- APRIME-2x: the real error is in the log, the notice is not --------------
run_test "APRIME-20" "new CLI, unclassified error: the FAILED line carries the real error text" \
  "grep -E 'FAILED' '$W/new_other.log' | grep -q 'image pull failed (no space left on device)'"
run_test "APRIME-21" "new CLI, unclassified error: the FAILED line does not show the deprecation notice" \
  "! grep -E 'FAILED' '$W/new_other.log' | grep -qi 'deprecated'"
run_test "APRIME-22" "old CLI, unclassified error: the FAILED line carries the real error text" \
  "grep -E 'FAILED' '$W/old_other.log' | grep -q 'image pull failed (no space left on device)'"
run_test "APRIME-23" "new CLI, registry auth: the log carries the real registry error" \
  "grep -E 'FAILED' '$W/new_auth.log' | grep -q 'pull access denied'"
run_test "APRIME-25" "new CLI, unclassified error: the full output is logged after the FAILED line" \
  "grep -A3 'FAILED (rc=' '$W/new_other.log' | grep -q '|.*image pull failed'"
run_test "APRIME-24" "run exercised 15+ stub calls (the harness ran the script, not nothing)" \
  "[ \$(cat '$W'/*.calls | wc -l) -ge 15 ]"

# --- APRIME-3x: "not ready to perform" is retried (Odoo #1610 finding C) -----
prime new notready nr_ok
prime old notready nr_old
GA_PRIME_RETRY_BUDGET_S=40 prime new notready_forever nr_forever
run_test "APRIME-30" "refused 3x with 'not ready to perform', then accepted: primed, marker, rc 0, 4 update calls" \
  "[ \"\$(rc nr_ok)\" = 0 ] && [ -f '$W/nr_ok.marker' ] && [ \"\$(grep -c '^ha apps update' '$W/nr_ok.calls')\" = 4 ] && grep -qx 'ha apps start GA-FAKE_ga_manager' '$W/nr_ok.calls'"
run_test "APRIME-31" "same on the old CLI generation, and the retries are logged" \
  "[ \"\$(rc nr_old)\" = 0 ] && [ -f '$W/nr_old.marker' ] && grep -q 'retry in' '$W/nr_old.log'"
run_test "APRIME-32" "never ready: bounded (budget 40 s = 5+10+20+30 waited, 5 attempts), then loud FAILED, rc 1, NO marker" \
  "[ \"\$(rc nr_forever)\" = 1 ] && [ ! -f '$W/nr_forever.marker' ] && [ \"\$(grep -c '^ha apps update' '$W/nr_forever.calls')\" = 5 ] && grep -q 'giving up' '$W/nr_forever.log' && grep -q 'FAILED (rc=1)' '$W/nr_forever.log'"
run_test "APRIME-33" "other errors are NOT retried: exactly one update call (unclassified, auth, missing)" \
  "[ \"\$(grep -c '^ha apps update' '$W/new_other.calls')\" = 1 ] && [ \"\$(grep -c '^ha apps update' '$W/new_auth.calls')\" = 1 ] && [ \"\$(grep -c '^ha apps update' '$W/new_miss.calls')\" = 1 ]"


# --- APRIME-4x: ONE global deadline, below the unit's TimeoutStartSec (Odoo #1610 review) ---
# clock <name> = seconds the fake clock advanced (the script's own waiting) in that run.
clock() { cat "$W/$1.clock" 2>/dev/null || echo 0; }
STUB_STATE=startup GA_PRIME_TOTAL_BUDGET_S=100 prime new ok dl_probe
run_test "APRIME-40" "Supervisor never ready, 100 s budget: stops at the deadline (not after 120 probes = 600 s), loud FAILED, rc 1, NO marker" \
  "[ \"\$(rc dl_probe)\" = 1 ] && [ ! -f '$W/dl_probe.marker' ] && [ \"\$(clock dl_probe)\" -le 110 ] && grep -q 'FAILED' '$W/dl_probe.log' && grep -q 'global deadline' '$W/dl_probe.log'"
GA_PRIME_TOTAL_BUDGET_S=60 GA_PRIME_RETRY_BUDGET_S=600 prime new notready_forever dl_retry
run_test "APRIME-42" "update refused 'not ready' forever, retry budget 600 s but global 60 s: gives up inside the global budget, loud FAILED, rc 1, NO marker" \
  "[ \"\$(rc dl_retry)\" = 1 ] && [ ! -f '$W/dl_retry.marker' ] && [ \"\$(clock dl_retry)\" -le 65 ] && grep -q 'global' '$W/dl_retry.log' && grep -q 'FAILED (rc=1)' '$W/dl_retry.log'"
STUB_HANG=1 GA_PRIME_TOTAL_BUDGET_S=2 prime new ok dl_hang
run_test "APRIME-43" "a hung docker call cannot outlive the budget: hard timeout, loud 'global deadline' FAILED line, rc 1, NO marker" \
  "[ \"\$(rc dl_hang)\" = 1 ] && [ ! -f '$W/dl_hang.marker' ] && grep -q 'FAILED — global deadline of 2s' '$W/dl_hang.log'"
UNIT="$R/buildroot-external/rootfs-overlay/usr/lib/systemd/system/ga-addon-prime.service"
run_test "APRIME-41" "the script's default budget is at least 30 s below the unit's TimeoutStartSec (both read from the live files)" \
  "t=\$(sed -n 's/^TimeoutStartSec=\\([0-9][0-9]*\\)min\$/\\1/p' '$UNIT'); b=\$(sed -n 's/^TOTAL_BUDGET_S=\"\\\${GA_PRIME_TOTAL_BUDGET_S:-\\([0-9][0-9]*\\)}\"\$/\\1/p' '$SUT'); [ -n \"\$t\" ] && [ -n \"\$b\" ] && [ \$((b + 30)) -le \$((t * 60)) ]"
# --- APRIME-5x: readiness is `ha info` state, never a store reload (Odoo #1752) ---
nreload() { grep -c '^ha store reload' "$W/$1.calls" || true; }
STUB_STARTUP_N=4 prime new ok rdy
STUB_STATE=startup GA_PRIME_TOTAL_BUDGET_S=100 prime new ok never
STUB_STORE=fail prime new ok f429
run_test "APRIME-50" "readiness: state startup x4 then running -> polls 'ha info' 5 times, primes, marker, rc 0, log names state=running" \
  "[ \"\$(rc rdy)\" = 0 ] && [ -f '$W/rdy.marker' ] && [ \"\$(grep -c '^ha info --raw-json' '$W/rdy.calls')\" = 5 ] && grep -q 'state=running' '$W/rdy.log' && grep -q 'state=startup' '$W/rdy.log'"
run_test "APRIME-51" "readiness wait (5 polls) issues at most ONE 'ha store reload' (old script: one per probe try)" \
  "[ \"\$(nreload rdy)\" -le 1 ]"
run_test "APRIME-52" "Supervisor stuck in startup until the deadline: ZERO store reloads, loud FAILED, rc 1, NO marker" \
  "[ \"\$(rc never)\" = 1 ] && [ \"\$(nreload never)\" = 0 ] && [ ! -f '$W/never.marker' ] && grep -q 'FAILED' '$W/never.log'"
run_test "APRIME-53" "the single reload comes AFTER readiness (after the last startup poll, before the first update)" \
  "[ \"\$(nreload new_ok)\" = 1 ] && [ \"\$(grep -n '^ha store reload' '$W/rdy.calls' | cut -d: -f1)\" -gt \"\$(grep -n '^ha info' '$W/rdy.calls' | tail -n 1 | cut -d: -f1)\" ]"
run_test "APRIME-54" "reload fails (429): called once (not retried), NO marker, rc 1, distinct 'store reload failed — prime incomplete' line" \
  "[ \"\$(nreload f429)\" = 1 ] && [ \"\$(rc f429)\" = 1 ] && [ ! -f '$W/f429.marker' ] && grep -q 'store reload failed — prime incomplete, retry next start' '$W/f429.log'"
STUB_STORE=fail prime new noupdate f429_nu
run_test "APRIME-55" "reload fails + 'no update available': NOT classified as OK (no marker, rc 1, 'NOT trusted' logged)" \
  "[ \"\$(rc f429_nu)\" = 1 ] && [ ! -f '$W/f429_nu.marker' ] && grep -q 'NOT trusted' '$W/f429_nu.log' && ! grep -q 'already at pinned version' '$W/f429_nu.log'"
run_test "APRIME-56" "reload OK + 'no update available': unchanged happy path (marker, rc 0, already pinned)" \
  "[ \"\$(rc new_noupd)\" = 0 ] && [ -f '$W/new_noupd.marker' ] && grep -q 'already at pinned version' '$W/new_noupd.log' && [ \"\$(nreload new_noupd)\" = 1 ]"
for m in rc1 empty garbage; do STUB_INFO_BAD=$m GA_PRIME_TOTAL_BUDGET_S=100 prime new ok info_$m; done
run_test "APRIME-57" "'ha info' failing (rc!=0) / empty / non-JSON: loops to the deadline, FAILED, rc 1, NO marker, zero store reloads" \
  "for m in rc1 empty garbage; do [ \"\$(rc info_\$m)\" = 1 ] && [ ! -f \"$W/info_\$m.marker\" ] && grep -q 'FAILED' \"$W/info_\$m.log\" && [ \"\$(nreload info_\$m)\" = 0 ] && [ \"\$(clock info_\$m)\" -le 110 ] || exit 1; done"

suite_end
