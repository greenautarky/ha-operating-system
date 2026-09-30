#!/bin/sh
# host_control — the host acts on control requests from ga_manager only when
# they sit in ga_manager's OWN data directory, under its pinned slug (ADR-0041):
#
#   /mnt/data/supervisor/addons/data/99f1cad4_ga_manager/
#
# and never on the same file in /mnt/data/supervisor/share, which is mounted
# into every add-on that declares `share:rw`.
#
# Four host actions are covered, each driven through the command its systemd
# unit actually runs (the ExecStart= line is read from the unit file, so a unit
# that points at a different verb or script is tested as it ships):
#
#   ga-rauc-install.path/.service  -> download + rauc install + reboot
#   ga-bluetooth.service           -> load the Bluetooth driver (managed / raw)
#   ga-ethernet-retire.path/.service -> delete /mnt/boot/ga-ethernet-force
#   ga-lte-standby-route.service   -> add / withdraw the wlan0 standby route
#
# plus ga-gm-host-release, which tells ga_manager which release this host runs.
#
# For each: a request placed ONLY in the shared directory must be ignored, the
# same request in ga_manager's data directory must be acted on, and a symlink
# or garbage request there must be refused. The path units must watch the
# pinned data path, and no path unit may watch the shared directory at all.
#
# How: like tests/ga_tests/share_writers, each real script runs inside a
# bubblewrap sandbox with a temp dir mounted at /mnt/data, /mnt/boot and /run,
# and the repository's /usr/libexec overlay at /usr/libexec. Only commands that
# reach hardware, the network, the disks or PID 1 are stubbed (curl, rauc,
# systemctl, modprobe, hciconfig, nmcli, ip, logger, sleep, sync — an unstubbed
# sync waits on every filesystem of the runner); each stub records its arguments so a
# check can assert what the script DID, not just its exit code.
set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
EXT="$ROOT/buildroot-external/rootfs-overlay"
IHOST="$ROOT/buildroot-ihost/rootfs-overlay"
EXT_UNITS="$EXT/usr/lib/systemd/system"
IHOST_UNITS="$IHOST/etc/systemd/system"
# Pinned here, not derived from the tree under test (working-method rule 7).
GM_HOST=/mnt/data/supervisor/addons/data/99f1cad4_ga_manager
SHARE_HOST=/mnt/data/supervisor/share

pass=0; fail=0
PASS() { echo "  PASS  $1"; pass=$((pass+1)); }
FAIL() { echo "  FAIL  $1${2:+ ($2)}"; fail=$((fail+1)); }
ok() { if eval "$2"; then PASS "$1"; else FAIL "$1" "${3:-}"; fi; }

# ── static: what the path units watch ──────────────────────────────────────
echo "--- path units watch ga_manager's pinned data directory ---"
unit_key() {  # <unit file> <key> -> value(s)
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1"
}
v=$(unit_key "$EXT_UNITS/ga-rauc-install.path" PathChanged)
ok "HCTL-01 ga-rauc-install.path watches $GM_HOST/ga-rauc-install-request" \
   "[ '$v' = '$GM_HOST/ga-rauc-install-request' ]" "watches '$v'"
v=$(unit_key "$IHOST_UNITS/ga-ethernet-retire.path" PathExists)
ok "HCTL-02 ga-ethernet-retire.path watches $GM_HOST/.ga_converged" \
   "[ '$v' = '$GM_HOST/.ga_converged' ]" "watches '$v'"
share_watchers=""
n_units=0
for u in "$EXT_UNITS"/*.path "$IHOST_UNITS"/*.path; do
  [ -f "$u" ] || continue
  n_units=$((n_units+1))
  if grep -qE "^Path(Exists|ExistsGlob|Changed|Modified|DirectoryNotEmpty)=$SHARE_HOST" "$u"; then
    share_watchers="$share_watchers $(basename "$u")"
  fi
done
# Assert coverage, not exit code: a scan over zero units proves nothing.
ok "HCTL-03 no path unit watches the shared directory ($n_units units scanned)" \
   "[ $n_units -ge 3 ] && [ -z '$share_watchers' ]" "scanned $n_units, watching share:$share_watchers"
v=$(unit_key "$EXT_UNITS/ga-gm-host-release.path" PathExists)
ok "HCTL-04 ga-gm-host-release.path watches $GM_HOST" "[ '$v' = '$GM_HOST' ]" "watches '$v'"
ok "HCTL-05 ga-gm-host-release service and path are enabled" \
   "[ -L '$EXT_UNITS/multi-user.target.wants/ga-gm-host-release.service' ] && [ -L '$EXT_UNITS/multi-user.target.wants/ga-gm-host-release.path' ]"

# ── the sandbox runner ──────────────────────────────────────────────────────
BWRAP=""
if command -v bwrap >/dev/null 2>&1; then
  if timeout 20 bwrap --unshare-net --unshare-pid --ro-bind / / --proc /proc --dev /dev true 2>/dev/null; then
    BWRAP="bwrap"
  elif timeout 20 sudo -n bwrap --unshare-net --unshare-pid --ro-bind / / --proc /proc --dev /dev true 2>/dev/null; then
    BWRAP="sudo -n bwrap"
  fi
fi
if [ -z "$BWRAP" ]; then
  echo "FATAL: bubblewrap cannot create a sandbox here — this suite must not pass without running" >&2
  exit 1
fi

WORK="$(mktemp -d -t host-control-XXXXXX)"
trap 'rm -rf "$WORK" 2>/dev/null || sudo -n rm -rf "$WORK" 2>/dev/null' EXIT

# Every stub appends "<name> <args>" to /mnt/data/.calls (inside the sandbox).
STUBS="$WORK/stubs"; mkdir -p "$STUBS"
for c in rauc systemctl modprobe hciconfig nmcli ip logger sleep sync; do
  printf '#!/bin/sh\necho "%s $*" >> /mnt/data/.calls\nexit 0\n' "$c" > "$STUBS/$c"
done
# curl: record, then write a dummy bundle to the --output path.
cat > "$STUBS/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >> /mnt/data/.calls
out=""
while [ $# -gt 0 ]; do case "$1" in --output|-o) out="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "$out" ] && echo bundle > "$out"
exit 0
EOF
chmod +x "$STUBS"/*
# /usr/sbin/modprobe is called by absolute path; shadow it when the host has one
# (a sandbox run under sudo must never load a module on the runner).
# bwrap cannot mount onto a symlink (/usr/sbin/modprobe -> ../bin/kmod on many
# distributions), so shadow what it resolves to.
MODPROBE_BIND=""
if [ -e /usr/sbin/modprobe ]; then
  MODPROBE_BIND="--ro-bind $STUBS/modprobe $(readlink -f /usr/sbin/modprobe)"
fi

fresh() {
  C="$WORK/case/$1"; rm -rf "$C" 2>/dev/null || sudo -n rm -rf "$C"
  mkdir -p "$C/data/supervisor/share" "$C/data/supervisor/addons/data/99f1cad4_ga_manager" \
           "$C/boot" "$C/run" "$C/tmp"
  printf 'UNRELATED-CONTENT-1\n' > "$C/data/other-file"
  : > "$C/data/.calls"
  SHARE="$C/data/supervisor/share"
  GM="$C/data/supervisor/addons/data/99f1cad4_ga_manager"
}

sbx() {  # <cmd...> — run inside the sandbox with $C mounted
  # shellcheck disable=SC2086  # $BWRAP and $MODPROBE_BIND must word-split
  timeout -k 5 60 $BWRAP --unshare-net --unshare-ipc --unshare-uts --unshare-pid --die-with-parent \
    --ro-bind / / --proc /proc --dev /dev \
    --tmpfs /mnt --bind "$C/data" /mnt/data --bind "$C/boot" /mnt/boot \
    --bind "$C/run" /run --bind "$C/tmp" /tmp \
    --ro-bind "$EXT/usr/libexec" /usr/libexec --ro-bind "$STUBS" /mnt/.stubs \
    --ro-bind "$EXT" /mnt/.ext --ro-bind "$IHOST" /mnt/.ihost \
    $MODPROBE_BIND \
    --setenv PATH "/mnt/.stubs:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$@"
}

# exec_of <unit file> -> the ExecStart command, with its script mapped to the
# overlay copy the sandbox sees. Empty when the unit or the script is missing.
exec_of() {
  _l=$(sed -n 's/^ExecStart=//p' "$1" 2>/dev/null | head -1)
  [ -n "$_l" ] || return 0
  _bin=${_l%% *}; _args=""
  [ "$_bin" = "$_l" ] || _args=${_l#* }
  for _o in ihost ext; do
    if [ "$_o" = ihost ]; then _src="$IHOST"; else _src="$EXT"; fi
    if [ -f "$_src$_bin" ]; then echo "/mnt/.$_o$_bin $_args"; return 0; fi
  done
}
run_unit() {  # <unit file> [env assignments...] — run the unit's ExecStart
  _u="$1"; shift
  _cmd=$(exec_of "$_u")
  if [ -z "$_cmd" ]; then echo "no runnable ExecStart in $_u" > "$C/out"; echo 127 > "$C/rc"; return; fi
  # The sentinel proves the script ran inside the sandbox. Without it every
  # "was ignored" check would pass on a sandbox that never started.
  # shellcheck disable=SC2086  # $_cmd is "<script> [args]"
  sbx env "$@" sh -c ': > /mnt/data/.ran; exec sh "$@"' _ $_cmd > "$C/out" 2>&1
  echo $? > "$C/rc"
  [ -e "$C/data/.ran" ] || FAIL "sandbox did not run $(basename "$_u")" "$(tr '\n' ';' < "$C/out")"
}
ran() { [ -e "$C/data/.ran" ]; }
calls() { cat "$C/data/.calls"; }
unchanged() { [ "$(cat "$C/data/other-file")" = UNRELATED-CONTENT-1 ]; }

# ── RAUC install request ────────────────────────────────────────────────────
echo "--- OS install request ---"
RAUC_SVC="$EXT_UNITS/ga-rauc-install.service"

fresh rauc-share
printf '16.3.1.9\n' > "$SHARE/ga-rauc-install-request"
printf 'BOSv1.4.1-rc1\n' > "$SHARE/ga-rauc-install-request.rc"
run_unit "$RAUC_SVC"
ok "HCTL-10 a request in the shared directory is ignored (no download, no install)" \
   "ran && ! calls | grep -qE '^(curl|rauc install)'" "calls: $(calls | tr '\n' ';')"
ok "HCTL-10b ... and left where it is (the host does not consume it)" \
   "[ -f '$SHARE/ga-rauc-install-request' ]"

fresh rauc-gm
printf '16.3.1.9\n' > "$GM/ga-rauc-install-request"
printf 'BOSv1.4.0-rc3\n' > "$GM/ga-rauc-install-request.rc"
run_unit "$RAUC_SVC"
ok "HCTL-11 a request in ga_manager's data directory is downloaded from the per-rc slot" \
   "calls | grep -q 'curl .*releases/16.3.1.9/BOSv1.4.0-rc3/haos_ihost-16.3.1.9.raucb'" "calls: $(calls | tr '\n' ';') out: $(tr '\n' ';' < "$C/out")"
ok "HCTL-11b ... installed with rauc" "calls | grep -q '^rauc install '"
ok "HCTL-11c ... and consumed (request + sidecar removed)" \
   "[ ! -e '$GM/ga-rauc-install-request' ] && [ ! -e '$GM/ga-rauc-install-request.rc' ]"

fresh rauc-link
printf '16.3.1.9\n' > "$C/data/other-version"
ln -s /mnt/data/other-version "$GM/ga-rauc-install-request"
run_unit "$RAUC_SVC"
ok "HCTL-12 a symlinked request is refused (no download)" \
   "ran && ! calls | grep -q '^curl' && [ \"\$(cat '$C/rc')\" != 0 ]" "rc=$(cat "$C/rc") calls: $(calls | tr '\n' ';')"
ok "HCTL-12b ... the link is removed and its target left intact" \
   "[ ! -e '$GM/ga-rauc-install-request' ] && [ ! -L '$GM/ga-rauc-install-request' ] && [ \"\$(cat '$C/data/other-version')\" = 16.3.1.9 ]"

fresh rauc-garbage
printf '16.3.1.9;reboot\n' > "$GM/ga-rauc-install-request"
run_unit "$RAUC_SVC"
ok "HCTL-13 a malformed version is refused (no download)" \
   "ran && ! calls | grep -q '^curl' && [ \"\$(cat '$C/rc')\" = 2 ]" "rc=$(cat "$C/rc")"

fresh rauc-rc-link
printf '16.3.1.9\n' > "$GM/ga-rauc-install-request"
printf 'BOSv1.4.1-rc1\n' > "$C/data/other-rc"
ln -s /mnt/data/other-rc "$GM/ga-rauc-install-request.rc"
run_unit "$RAUC_SVC"
ok "HCTL-14 a symlinked release sidecar is refused (no download)" \
   "ran && ! calls | grep -q '^curl'" "calls: $(calls | tr '\n' ';')"

# ── Bluetooth gate ──────────────────────────────────────────────────────────
echo "--- Bluetooth gate ---"
BT_SVC="$IHOST_UNITS/ga-bluetooth.service"

fresh bt-share
printf '1\n' > "$SHARE/ga-bluetooth-enabled"
run_unit "$BT_SVC"
ok "HCTL-20 an enable flag in the shared directory is ignored (Bluetooth stays off)" \
   "ran && [ ! -e '$C/run/ga-bluetooth.enabled' ]" "out: $(tr '\n' ';' < "$C/out")"

fresh bt-gm
printf '1\n' > "$GM/ga-bluetooth-enabled"
run_unit "$BT_SVC"
ok "HCTL-21 an enable flag in ga_manager's data directory turns Bluetooth on (source=config)" \
   "[ -e '$C/run/ga-bluetooth.enabled' ] && grep -q 'source=config' '$C/out'" "out: $(tr '\n' ';' < "$C/out")"

fresh bt-link
printf '1\n' > "$C/data/other-flag"
ln -s /mnt/data/other-flag "$GM/ga-bluetooth-enabled"
run_unit "$BT_SVC"
ok "HCTL-22 a symlinked enable flag is refused (Bluetooth stays off)" \
   "ran && [ ! -e '$C/run/ga-bluetooth.enabled' ]"

fresh bt-mode-share
printf '1\n' > "$GM/ga-bluetooth-enabled"
printf 'raw\n' > "$SHARE/ga-bluetooth-mode"
run_unit "$BT_SVC"
ok "HCTL-23 a mode file in the shared directory is ignored (managed, not raw)" \
   "[ -e '$C/run/ga-bluetooth.enabled' ] && [ ! -e '$C/run/ga-bluetooth.raw' ]"

fresh bt-mode-gm
printf '1\n' > "$GM/ga-bluetooth-enabled"
printf 'raw\n' > "$GM/ga-bluetooth-mode"
run_unit "$BT_SVC"
ok "HCTL-24 mode raw in ga_manager's data directory is applied" \
   "[ -e '$C/run/ga-bluetooth.raw' ]"

# ── Ethernet override retirement ────────────────────────────────────────────
echo "--- Ethernet override retirement ---"
RET_SVC="$IHOST_UNITS/ga-ethernet-retire.service"

fresh eth-share
: > "$C/boot/ga-ethernet-force"
printf 'converged\n' > "$SHARE/.ga_converged"
run_unit "$RET_SVC"
ok "HCTL-30 a converged marker in the shared directory retires nothing" \
   "ran && [ -e '$C/boot/ga-ethernet-force' ]" "out: $(tr '\n' ';' < "$C/out")"
ok "HCTL-30b ... and the unit still exits 0, so its disarm step runs (no re-trigger loop)" \
   "[ \"\$(cat '$C/rc')\" = 0 ]" "rc=$(cat "$C/rc")"

fresh eth-gm
: > "$C/boot/ga-ethernet-force"
printf 'converged\n' > "$GM/.ga_converged"
run_unit "$RET_SVC"
ok "HCTL-31 the converged marker in ga_manager's data directory retires the override" \
   "[ ! -e '$C/boot/ga-ethernet-force' ] && [ \"\$(cat '$C/rc')\" = 0 ]" "rc=$(cat "$C/rc") out: $(tr '\n' ';' < "$C/out")"

fresh eth-link
: > "$C/boot/ga-ethernet-force"
ln -s /mnt/data/other-file "$GM/.ga_converged"
run_unit "$RET_SVC"
ok "HCTL-32 a symlinked converged marker retires nothing, exit 0" \
   "[ -e '$C/boot/ga-ethernet-force' ] && [ \"\$(cat '$C/rc')\" = 0 ] && grep -q 'not a regular file' '$C/out'" "rc=$(cat "$C/rc") out: $(tr '\n' ';' < "$C/out")"

# ── LTE standby route ───────────────────────────────────────────────────────
echo "--- LTE standby route ---"
LTE_SVC="$IHOST_UNITS/ga-lte-standby-route.service"
VERDICT_OK='{"usable":true,"since":"x","reason":"up","updated_at":"y"}'

fresh lte-share
printf '%s\n' "$VERDICT_OK" > "$SHARE/ga-lte-standby.json"
run_unit "$LTE_SVC"
ok "HCTL-40 a usable verdict in the shared directory adds no route" \
   "ran && ! calls | grep -q '^ip -4 route add'" "calls: $(calls | tr '\n' ';')"

fresh lte-gm
printf '%s\n' "$VERDICT_OK" > "$GM/ga-lte-standby.json"
run_unit "$LTE_SVC"
ok "HCTL-41 a usable verdict in ga_manager's data directory adds the standby route" \
   "calls | grep -qE '^ip -4 route add default via [^ ]+ dev wlan0 metric 20500'" "calls: $(calls | tr '\n' ';')"

fresh lte-link
printf '%s\n' "$VERDICT_OK" > "$C/data/other-verdict"
ln -s /mnt/data/other-verdict "$GM/ga-lte-standby.json"
run_unit "$LTE_SVC"
ok "HCTL-42 a symlinked verdict adds no route and says why" \
   "! calls | grep -q '^ip -4 route add' && calls | grep -q 'not a regular file'" "calls: $(calls | tr '\n' ';')"

fresh lte-garbage
printf 'not json\n' > "$GM/ga-lte-standby.json"
run_unit "$LTE_SVC"
ok "HCTL-43 a verdict without a usable field adds no route and says why" \
   "! calls | grep -q '^ip -4 route add' && calls | grep -q 'usable field'" "calls: $(calls | tr '\n' ';')"

# ── the host tells ga_manager its release ──────────────────────────────────
echo "--- host release for ga_manager ---"
HR_SVC="$EXT_UNITS/ga-gm-host-release.service"

fresh hr-ok
printf 'BOSv1.4.0-rc3\n' > "$C/data/ga-release"
run_unit "$HR_SVC" GA_RELEASE_FILE=/mnt/data/ga-release
ok "HCTL-50 the release is published into ga_manager's data directory" \
   "[ -f '$GM/ga-host-release' ] && [ ! -L '$GM/ga-host-release' ] && [ \"\$(cat '$GM/ga-host-release')\" = BOSv1.4.0-rc3 ]" "rc=$(cat "$C/rc") out: $(tr '\n' ';' < "$C/out")"

fresh hr-link
printf 'BOSv1.4.0-rc3\n' > "$C/data/ga-release"
ln -s /mnt/data/other-file "$GM/ga-host-release"
run_unit "$HR_SVC" GA_RELEASE_FILE=/mnt/data/ga-release
ok "HCTL-51 a symlink at the target is replaced, never followed" \
   "unchanged && [ -f '$GM/ga-host-release' ] && [ ! -L '$GM/ga-host-release' ]"

fresh hr-garbage
printf 'dev-build\n' > "$C/data/ga-release"
run_unit "$HR_SVC" GA_RELEASE_FILE=/mnt/data/ga-release
ok "HCTL-52 a release that is not a GA label is not published, and the unit fails loudly" \
   "[ ! -e '$GM/ga-host-release' ] && [ \"\$(cat '$C/rc')\" != 0 ] && grep -q WARNING '$C/out'" "rc=$(cat "$C/rc")"

fresh hr-nodir
rmdir "$GM"
printf 'BOSv1.4.0-rc3\n' > "$C/data/ga-release"
run_unit "$HR_SVC" GA_RELEASE_FILE=/mnt/data/ga-release
ok "HCTL-53 without ga_manager's data directory nothing is created, exit 0" \
   "[ ! -e '$GM' ] && [ \"\$(cat '$C/rc')\" = 0 ]" "rc=$(cat "$C/rc")"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$pass" -gt 0 ] || { echo "FATAL: no check passed — the suite did not run" >&2; exit 1; }
exit "$fail"
