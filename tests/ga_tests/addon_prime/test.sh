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
W="$(mktemp -d 2>/dev/null || echo /tmp/addon_prime_$$)"
mkdir -p "$W/bin"

case "$MODE" in
  new) SUT="$LIVE" ;;
  old)
    REF="${GA_PRIME_BASELINE_REF:?old mode needs GA_PRIME_BASELINE_REF (a git ref with the previous script)}"
    git -C "$R" show "$REF:$REL" > "$W/old-script" || { echo "cannot read $REF:$REL"; exit 2; }
    sed -e 's|^PRIME_CONF="/etc/ga-addon-prime.conf"|PRIME_CONF="${GA_PRIME_CONF:-/etc/ga-addon-prime.conf}"|' \
        -e 's|^MARKER="/mnt/data/.ga-addon-primed"|MARKER="${GA_PRIME_MARKER:-/mnt/data/.ga-addon-primed}"|' \
        "$W/old-script" > "$W/sut"
    [ "$(grep -c 'GA_PRIME_' "$W/sut")" -eq 2 ] || { echo "baseline path hooks not applied"; exit 2; }
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
        other) echo "Error: Can't update $2: image pull failed (no space left on device)" >&2; exit 1 ;;
      esac ;;
  esac
  exit 0
}
case "$1" in
  store) exit 0 ;;
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
printf '#!/bin/sh\nexit 0\n' > "$W/bin/sleep"
chmod +x "$W/bin/docker" "$W/bin/sleep"
printf 'GA-FAKE_ga_manager\n' > "$W/prime.conf"

# prime <gen> <scenario> <name> — run the script; leaves $W/<name>.{log,rc,calls,marker}
prime() {
  rm -f "$W/$3.marker" "$W/$3.calls"; : > "$W/$3.calls"
  PATH="$W/bin:$PATH" TMPDIR="$W" STUB_GEN="$1" STUB_SCEN="$2" STUB_CALLS="$W/$3.calls" \
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

suite_end
