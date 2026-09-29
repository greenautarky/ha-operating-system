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
#     everybody out of a device that was working a second earlier.
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

echo "── the label bridge from ga_manager (/share) ──"
lab() {  # <dir> <bridge-content|-> [ca|noca]
  local d="$1"
  [[ "$2" != "-" ]] && printf '%s' "$2" > "$d/bridge"
  [[ "${3:-ca}" == "ca" ]] && printf 'ssh-ed25519 AAAA test-ca\n' > "$d/ca.pub"
  GA_SSH_CA_PUB="$d/ca.pub" GA_SSH_LABEL_BRIDGE="$d/bridge" GA_SSH_PRINCIPALS_DIR="$d" \
  GA_SSH_PRINCIPALS_BIN="$PRINCIPALS" /bin/sh "$LABELER" 2>/dev/null
}
d="$(fresh lab-ok)"; P "$d" anchor "RV1109SERIAL0001" >/dev/null; lab "$d" $'KIB-SON-00000901\n'
eq "$d" "RV1109SERIAL0001 KIB-SON-00000901 " "bridge label applied, anchor kept"
d="$(fresh lab-two)"; P "$d" anchor "RV1109SERIAL0001" >/dev/null; lab "$d" $'KIB-SON-00000901\nkibu\n'
eq "$d" "RV1109SERIAL0001 " "two-line bridge refused whole (no first-line trimming)"
d="$(fresh lab-bad)"; P "$d" anchor "RV1109SERIAL0001" >/dev/null; lab "$d" $'kibu\n'
eq "$d" "RV1109SERIAL0001 " "bridge label 'kibu' refused by the writer"
d="$(fresh lab-noca)"; lab "$d" $'KIB-SON-00000901\n' noca;                ran=$((ran + 1))
if [[ -e "$d/root" ]]; then bad "no CA baked but the bridge label was applied"
else ok "no CA baked (below BOSv1.4.0) → bridge ignored"; fi

echo
if (( ran < 23 )); then echo "${RED}FAIL${NC}  only $ran cases ran — expected at least 23"; exit 1; fi
if (( fails > 0 )); then echo "${RED}${fails} of ${ran} case(s) failed${NC}"; exit 1; fi
echo "${GRN}all ${ran} cases passed${NC}"
