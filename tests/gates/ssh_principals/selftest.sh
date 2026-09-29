#!/usr/bin/env bash
# =============================================================================
# selftest.sh — the certificate principal: anchor and label (ADR-0019 amd. C)
# =============================================================================
# The principal is what stops a certificate issued for one device from opening
# another. Two ways to get that wrong, neither visible in a normal run:
#
#   * accept a name that is not per-device — every device ships as "kibu", so a
#     certificate naming it would open every not-yet-onboarded device at once;
#   * let one writer clobber the other — if the fleet-manager's label write
#     dropped the device's own anchor, a rename or an outage would lock
#     everybody out of a device that was working a second earlier;
#   * take the label from anything but ga_manager's own data dir as a plain,
#     small, regular file — or accept a label naming a different device.
#
# So this runs the LIVE scripts against fixture trees in both directions.
# Offline, no device, no build.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
LIB="$ROOT/buildroot-external/rootfs-overlay/usr/libexec"
PRINCIPALS="$LIB/ga-ssh-principals"
PREPARE="$LIB/ga-sshd-prepare"
LABELER="$LIB/ga-ssh-principal-label"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; NC=$'\033[0m'
fails=0; ran=0
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$NC" "$*"; fails=$((fails + 1)); }
ok()  { printf '  %sok%s    %s\n' "$GRN" "$NC" "$*"; }
[[ -x "$PRINCIPALS" ]] || { echo "FATAL: $PRINCIPALS missing"; exit 1; }
[[ -x "$PREPARE"    ]] || { echo "FATAL: $PREPARE missing"; exit 1; }
[[ -x "$LABELER"    ]] || { echo "FATAL: $LABELER missing"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fresh() { local d="$WORK/$1"; rm -rf "$d"; mkdir -p "$d"; printf '%s' "$d"; }
P() { GA_SSH_PRINCIPALS_DIR="$1" /bin/sh "$PRINCIPALS" "${@:2}" 2>/dev/null; }
lines() { tr '\n' ' ' < "$1/root" 2>/dev/null; }
# NOT `[[ ... ]] && ok || bad` — that runs bad() whenever ok() fails, which
# is how a suite starts reporting failures it did not have (SC2015).
eq() {  # <dir> <expected> <description>
  local got; got="$(lines "$1")"; ran=$((ran + 1))
  if [[ "$got" == "$2" ]]; then ok "$3 → $got"; else bad "$3 → got '$got', want '$2'"; fi
}

refuse() {  # <dir> <role> <identity> <description>
  ran=$((ran + 1))
  if P "$1" "$2" "$3"; then bad "accepted $2 '$3' — $4"; else ok "refused $2 '$3' — $4"; fi
}

echo "── names the device must refuse ──"
d="$(fresh refuse)"
refuse "$d" label  "kibu"              "the name EVERY device ships with"
refuse "$d" label  "*"                 "wildcard"
refuse "$d" label  "KIB-SON-31"        "short form — not the 8-digit fleet id"
refuse "$d" label  "KIB-SON-00000901 KIB-SON-00000902" "two ids in one value"
refuse "$d" label  $'KIB-SON-00000901\nKIB-SON-00000902' "newline injection"
refuse "$d" label  ""                  "empty label"
refuse "$d" anchor ""                  "empty anchor"
refuse "$d" anchor "serial with space" "anchor outside the charset"
refuse "$d" bogus  "x"                 "unknown role"
ran=$((ran + 1))
if [[ -e "$d/root" ]]; then bad "a refused write still created a principals file"
else ok "no principals file created by any refused write"; fi

echo "── the two writers must not clobber each other ──"
d="$(fresh both)"
P "$d" anchor "ABCDEF0123456789" >/dev/null
eq "$d" "ABCDEF0123456789 " "anchor alone"
P "$d" label "KIB-SON-00000901" >/dev/null
eq "$d" "ABCDEF0123456789 KIB-SON-00000901 " "label added, anchor kept"

# The case that matters on a rename: the fleet-manager rewrites the label and
# the device's own anchor has to survive it, or a rename is a lockout.
P "$d" label "KIB-SON-00000909" >/dev/null
eq "$d" "ABCDEF0123456789 KIB-SON-00000909 " "label REWRITTEN, anchor survives"

P "$d" anchor "FEDCBA9876543210" >/dev/null
eq "$d" "FEDCBA9876543210 KIB-SON-00000909 " "anchor rewritten, label survives"

d="$(fresh dedup)"
P "$d" anchor "KIB-SON-00000901" >/dev/null; P "$d" label "KIB-SON-00000901" >/dev/null
eq "$d" "KIB-SON-00000901 " "identical anchor and label are deduplicated"

echo "── the anchor must come from HARDWARE, never from machine-id ──"
# Drives the LIVE ga-sshd-prepare (never a copy of its anchor logic) with the
# device paths moved into the fixture dir.
prep() {  # <dir> <dt-serial|-> <cpuinfo-body|-> [ca|noca]
  local d="$1"
  [[ "$2" != "-" ]] && printf '%s\0' "$2" > "$d/dt-serial"
  [[ "$3" != "-" ]] && printf '%s\n' "$3" > "$d/cpuinfo"
  [[ "${4:-ca}" == "ca" ]] && printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureFixtureFixtureFixtureFixtureFixture01 test-ca\n' > "$d/ca.pub"
  GA_SSHD_KEYDIR="$d/keys" GA_SSH_CA_PUB="$d/ca.pub" GA_SSH_PRINCIPALS_DIR="$d" \
  GA_SSH_PRINCIPALS_BIN="$PRINCIPALS" GA_DT_SERIAL="$d/dt-serial" GA_CPUINFO="$d/cpuinfo" \
  GA_SSHD_PREPARE_VAR_EMPTY=0 /bin/sh "$PREPARE" 2>/dev/null
}
d="$(fresh dt)";   prep "$d" "RV1109SERIAL0001" "-"
eq "$d" "RV1109SERIAL0001 " "devicetree serial → anchored"
d="$(fresh cpu)";  prep "$d" "-" $'processor\t: 0\nSerial\t\t: CPUSERIAL00042'
eq "$d" "CPUSERIAL00042 " "cpuinfo Serial → anchored"
d="$(fresh none)"; prep "$d" "-" "-";                                      ran=$((ran + 1))
if [[ -e "$d/root" ]]; then bad "no hardware serial but a principal was written anyway"
else ok "no hardware serial → NO anchor (machine-id refused), break-glass only"; fi

d="$(fresh noca)"; prep "$d" "RV1109SERIAL0001" "-" noca;               ran=$((ran + 1))
if [[ -e "$d/root" ]]; then bad "shared-plane image (no CA baked) but a principal was written"
else ok "no CA baked (below BOSv1.4.0) → prepare leaves the principals alone"; fi

echo "── the label from ga_manager (its own data dir, pinned slug) ──"
# lab <dir> <source-content|-> [ca|noca] [own-label|-]
# Every path is inside <dir>; stderr goes to <dir>/err so the no-echo cases
# can read what would have reached the journal.
lab() {
  local d="$1"
  [[ "$2" != "-" ]] && printf '%s' "$2" > "$d/src"
  [[ "${3:-ca}" == "ca" ]] && printf 'ssh-ed25519 AAAA test-ca\n' > "$d/ca.pub"
  [[ "${4:--}" != "-" ]] && printf '%s\n' "$4" > "$d/own-label"
  GA_SSH_CA_PUB="$d/ca.pub" GA_SSH_LABEL_BRIDGE="$d/src" GA_DEVICE_LABEL_FILE="$d/own-label" \
  GA_SSH_PRINCIPALS_DIR="$d" GA_SSH_PRINCIPALS_BIN="$PRINCIPALS" \
  /bin/sh "$LABELER" 2>"$d/err"
}
anchored() { local d; d="$(fresh "$1")"; P "$d" anchor "RV1109SERIAL0001" >/dev/null; printf '%s' "$d"; }
d="$(anchored lab-ok)"; lab "$d" $'KIB-SON-00000901\n'
eq "$d" "RV1109SERIAL0001 KIB-SON-00000901 " "label applied, anchor kept (no own-label file)"
ran=$((ran + 1))
if grep -q "no .*ga-device-label\|no .*own-label" "$d/err"; then ok "accepting without an own-label file says why"
else bad "accepted without an own-label file but did not say why: $(cat "$d/err")"; fi
d="$(anchored lab-two)"; lab "$d" $'KIB-SON-00000901\nkibu\n'
eq "$d" "RV1109SERIAL0001 " "two-line value refused whole (no first-line trimming)"
d="$(anchored lab-bad)"; lab "$d" $'kibu\n'
eq "$d" "RV1109SERIAL0001 " "label 'kibu' refused"
d="$(fresh lab-noca)"; lab "$d" $'KIB-SON-00000901\n' noca;                ran=$((ran + 1))
if [[ -e "$d/root" ]]; then bad "no CA baked but the label was applied"
else ok "no CA baked (below BOSv1.4.0) → label ignored"; fi

echo "── (ii) the label must be THIS device's when the device knows its own ──"
d="$(anchored own-match)"; lab "$d" $'KIB-SON-00000901\n' ca "KIB-SON-00000901"
eq "$d" "RV1109SERIAL0001 KIB-SON-00000901 " "label equals /mnt/data/ga-device-label → applied"
d="$(anchored own-foreign)"; lab "$d" $'KIB-SON-00000955\n' ca "KIB-SON-00000901"
eq "$d" "RV1109SERIAL0001 " "FOREIGN label (another device's) refused"
d="$(anchored own-garbage)"; lab "$d" $'KIB-SON-00000901\n' ca "not-a-label"
eq "$d" "RV1109SERIAL0001 " "own-label file unusable → refused (fail closed)"
d="$(anchored own-rename)"; lab "$d" $'KIB-SON-00000901\n' ca "KIB-SON-00000901"
lab "$d" $'KIB-SON-00000955\n' ca "KIB-SON-00000901"
eq "$d" "RV1109SERIAL0001 KIB-SON-00000901 " "a later foreign label does not replace the device's own"

echo "── (iii) a symlink is refused, and nothing from its target is echoed ──"
ONELINE="deadbeefcafef00d1234567890abcdef"
d="$(anchored sym-other)"; printf '%s\n' "$ONELINE" > "$d/other"; ln -s "$d/other" "$d/src"; lab "$d" -
eq "$d" "RV1109SERIAL0001 " "symlink to a one-line file → principals unchanged"
ran=$((ran + 1))
if grep -q "$ONELINE" "$d/err"; then bad "the symlink target's content reached stderr (journal): $(cat "$d/err")"
else ok "symlink target's content not echoed"; fi
d="$(anchored sym-valid)"; printf 'KIB-SON-00000901\n' > "$d/elsewhere"; ln -s "$d/elsewhere" "$d/src"; lab "$d" -
eq "$d" "RV1109SERIAL0001 " "symlink even to a VALID label → refused (regular file required)"
d="$(anchored echo-direct)"; ran=$((ran + 1))
# Captured first: under pipefail, `writer | grep -q` takes the writer's
# non-zero exit and would report "not echoed" whatever grep found.
out="$(GA_SSH_PRINCIPALS_DIR="$d" /bin/sh "$PRINCIPALS" label "$ONELINE" 2>&1)"
if [[ "$out" == *"$ONELINE"* ]]; then
  bad "ga-ssh-principals echoes a refused value"
else ok "ga-ssh-principals does not echo a refused value"; fi
d="$(anchored echo-shaped)"; lab "$d" $'not-a-label-0042\n';             ran=$((ran + 1))
if grep -q "not-a-label-0042" "$d/err"; then bad "a refused regular-file value was echoed: $(cat "$d/err")"
else ok "a refused regular-file value is not echoed"; fi

echo "── (iv) a source that never ends must not hang the unit ──"
prompt() {  # <dir> <description> — runs lab under a 5 s bound
  local d="$1" rc=0; ran=$((ran + 1))
  timeout 5 bash -c "$(declare -f lab); PRINCIPALS='$PRINCIPALS' LABELER='$LABELER' lab '$d' -" || rc=$?
  if (( rc == 124 )); then bad "$2 — did not finish within 5 s"
  elif (( rc == 0 )); then bad "$2 — accepted (rc 0)"
  else ok "$2 — refused promptly (rc $rc)"; fi
}
d="$(anchored dev-zero)"; ln -s /dev/zero "$d/src"; prompt "$d" "symlink to /dev/zero"
d="$(anchored fifo)"; mkfifo "$d/src"; prompt "$d" "a FIFO with no writer"
d="$(anchored huge)"; truncate -s 1G "$d/src"; prompt "$d" "a 1 GiB sparse regular file"
eq "$d" "RV1109SERIAL0001 " "the 1 GiB file changed nothing"

echo "── (i) the default paths: ga_manager's /data under the pinned slug, never /share ──"
UNITS="$ROOT/buildroot-external/rootfs-overlay/usr/lib/systemd/system"
PRIME="$ROOT/buildroot-external/rootfs-overlay/etc/ga-addon-prime.conf"
SLUG="$(grep -vE '^[[:space:]]*(#|$)' "$PRIME" | grep '_ga_manager$' | head -1)"
WANT="/mnt/data/supervisor/addons/data/$SLUG/ga-ssh-principal-label"
PATH_UNIT="$(sed -n 's/^PathChanged=//p' "$UNITS/ga-ssh-principal-label.path")"
# shellcheck disable=SC2016  # the literal default text in the script
SCRIPT_DEF="$(sed -n 's/^SRC="\${GA_SSH_LABEL_BRIDGE:-\$R\(.*\)}"$/\1/p' "$LABELER")"
ran=$((ran + 1))
if [[ "$SLUG" == "99f1cad4_ga_manager" ]]; then ok "pinned slug from ga-addon-prime.conf: $SLUG"
else bad "pinned slug from ga-addon-prime.conf is '$SLUG', want 99f1cad4_ga_manager"; fi
ran=$((ran + 1))
if [[ "$PATH_UNIT" == "$WANT" ]]; then ok ".path unit watches $WANT"
else bad ".path unit watches '$PATH_UNIT', want '$WANT'"; fi
ran=$((ran + 1))
if [[ "$SCRIPT_DEF" == "$WANT" ]]; then ok "script's default source is the same path"
else bad "script's default source is '$SCRIPT_DEF' (extraction empty = script changed shape), want '$WANT'"; fi
ran=$((ran + 1))
if grep -vE '^\s*#' "$LABELER" "$UNITS/ga-ssh-principal-label.path" "$UNITS/ga-ssh-principal-label.service" | grep -q 'supervisor/share\|\*_ga_manager'; then
  bad "the label plumbing still names /share or globs *_ga_manager"
else ok "no /share path and no *_ga_manager glob in the label plumbing"; fi
ran=$((ran + 1))
if grep -qE '^TimeoutStartSec=[0-9]' "$UNITS/ga-ssh-principal-label.service"; then ok "the oneshot has a TimeoutStartSec"
else bad "the oneshot has no TimeoutStartSec — a stuck read would hold it for ever"; fi

# Behavioural half, run through the DEFAULTS (GA_ROOT only): a label at the
# old share path changes nothing; the same label at the new path is applied.
groot() { local r; r="$(fresh "$1")"; mkdir -p "$r/etc/ssh" "$r/p" "$r/mnt/data/supervisor/share" "$r/mnt/data/supervisor/addons/data/$SLUG"
  printf 'ssh-ed25519 AAAA test-ca\n' > "$r/etc/ssh/ga_user_ca.pub"; P "$r/p" anchor "RV1109SERIAL0001" >/dev/null; printf '%s' "$r"; }
gl() { GA_ROOT="$1" GA_SSH_PRINCIPALS_DIR="$1/p" GA_SSH_PRINCIPALS_BIN="$PRINCIPALS" /bin/sh "$LABELER" 2>/dev/null; }
r="$(groot old-share)"; printf 'KIB-SON-00000901\n' > "$r/mnt/data/supervisor/share/ga-ssh-principal-label"; gl "$r"
eq "$r/p" "RV1109SERIAL0001 " "a label at the OLD /share path changes nothing"
r="$(groot new-data)"; printf 'KIB-SON-00000901\n' > "$r/mnt/data/supervisor/addons/data/$SLUG/ga-ssh-principal-label"; gl "$r"
eq "$r/p" "RV1109SERIAL0001 KIB-SON-00000901 " "the same label in ga_manager's /data is applied"
r="$(groot new-data-foreign)"; printf 'KIB-SON-00000901\n' > "$r/mnt/data/supervisor/addons/data/$SLUG/ga-ssh-principal-label"
printf 'KIB-SON-00000955' > "$r/mnt/data/ga-device-label"; gl "$r"
eq "$r/p" "RV1109SERIAL0001 " "default own-label path is read: another device's label refused"

echo
if (( ran < 45 )); then echo "${RED}FAIL${NC}  only $ran cases ran — expected at least 45"; exit 1; fi
if (( fails > 0 )); then echo "${RED}${fails} of ${ran} case(s) failed${NC}"; exit 1; fi
echo "${GRN}all ${ran} cases passed${NC}"
