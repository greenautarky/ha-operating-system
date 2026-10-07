#!/usr/bin/env bash
# =============================================================================
# selftest.sh — a kernel that fails to LOAD still costs its slot an attempt
# =============================================================================
# The iHost boot script (uboot-boot.ush) counts boot attempts per slot
# (BOOT_A_LEFT / BOOT_B_LEFT) and stores them before it boots. When no slot's
# kernel could be loaded, the script used to reset BOTH counters to 3 and
# store that. The counters then never went down, so a slot whose kernel could
# not be read was never given up on. Upstream HAOS fixed the identical code
# for ODROID-N2 in b704298a (#4832): store the decremented counters, and re-arm
# only once both slots are exhausted.
#
# This gate runs the slot-selection tail of the LIVE script (from
# `setenv bootargs` up to `echo "Starting kernel"`) under bash, across
# consecutive boots, with the U-Boot commands it uses stubbed:
#   setenv / setexpr  -> shell variables / arithmetic
#   part / load       -> which slot's kernel loads is the scenario's choice
#   run storebootstate-> records the counters the device would persist
#   reset             -> records the reset
# The counters persisted by one boot are the input of the next.
#
# Two textual adaptations are needed for bash and both must match exactly once
# or the gate FAILS (a rewrite that stops matching means the gate no longer
# runs the live script):
#   * `for BOOT_SLOT in "${BOOT_ORDER}"` -> unquoted (U-Boot's hush splits it;
#     upstream relies on that for the A -> B fallback)
#   * the comment-only `then` branch (`# skip remaining slots`) -> `:`
#
# What it cannot prove — the device run must: that U-Boot's hush parses the
# script (mkimage and a real boot), and a real failed kernel load on eMMC.
#
# must-flag: the live script with the "both exhausted" guard removed (the
# pre-fix shape) must fail the count-down case, and only that case.
# must-pass: the live script in every case.
# -----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
USH="$ROOT/buildroot-ihost/board/sonoff/ihost/uboot-boot.ush"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=''; GRN=''; NC=''; }
fails=0; ran=0
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$NC" "$*"; fails=$((fails + 1)); }
ok()  { printf '  %sok%s    %s\n' "$GRN" "$NC" "$*"; }
[[ -s "$USH" ]] || { echo "FATAL: $USH missing"; exit 1; }
command -v python3 >/dev/null || { echo "FATAL: python3 required"; exit 1; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# ── the slot-selection tail of a boot script, made runnable by bash ─────────
extract() {  # <boot script> <out>
  python3 - "$1" "$2" <<'PY' || return 1
import sys
src, out = sys.argv[1:3]
lines = open(src).read().split("\n")
def one(pred, what):
    idx = [i for i, l in enumerate(lines) if pred(l)]
    if len(idx) != 1:
        sys.exit("FATAL: expected exactly one %s line, found %d" % (what, len(idx)))
    return idx[0]
start = one(lambda l: l.strip() == "setenv bootargs", "'setenv bootargs'")
end = one(lambda l: l.strip() == 'echo "Starting kernel"', "'echo \"Starting kernel\"'")
if end <= start:
    sys.exit("FATAL: 'echo \"Starting kernel\"' precedes 'setenv bootargs'")
body = lines[start:end]
def sub(old, new, what):
    hits = [i for i, l in enumerate(body) if l.strip() == old]
    if len(hits) != 1:
        sys.exit("FATAL: expected exactly one %s line in the slot loop, found %d" % (what, len(hits)))
    i = hits[0]
    body[i] = body[i].replace(old, new)
sub('for BOOT_SLOT in "${BOOT_ORDER}"; do', 'for BOOT_SLOT in ${BOOT_ORDER}; do', "for-BOOT_ORDER")
sub("# skip remaining slots", ":", "'# skip remaining slots'")
open(out, "w").write("\n".join(body) + "\n")
PY
}

# One boot. Input: persisted counters + which slots' kernels load.
# Output: "<stored A> <stored B> <slot booted or -> <reset 0|1>"; stored = "-"
# when the script did not store (the persisted values then stay).
boot() {  # <tail.sh> <A_LEFT> <B_LEFT> <A loads 0|1> <B loads 0|1>
  bash -c '
    set -u
    TAIL=$1; BOOT_A_LEFT=$2; BOOT_B_LEFT=$3; LOAD_A=$4; LOAD_B=$5
    BOOT_ORDER="A B"; devnum=0; kernel_addr_r=0; cmdline=""; bootargs_ga=""
    bootargs_hassos=""; bootargs_a="slotA"; bootargs_b="slotB"
    STORED="- -"; RESET=0
    setenv()  { local n=$1; shift; printf -v "$n" "%s" "$*"; }
    setexpr() { printf -v "$1" "%s" "$(( $2 $3 $4 ))"; }
    part()    { [ "$1" = number ] && printf -v "$5" "%s" "$4"; }
    load()    { case "$2" in
                  *:hassos-kernel0) [ "$LOAD_A" = 1 ] ;;
                  *:hassos-kernel1) [ "$LOAD_B" = 1 ] ;;
                  *) echo "load: unexpected device $2" >&2; exit 97 ;;
                esac; }
    run()     { [ "$1" = storebootstate ] || { echo "run: unexpected $1" >&2; exit 98; }
                STORED="$BOOT_A_LEFT $BOOT_B_LEFT"; }
    reset()   { RESET=1; }
    echo()    { :; }
    # shellcheck disable=SC1090
    . "$TAIL"
    case "$bootargs" in *slotA*) S=A ;; *slotB*) S=B ;; *) S=- ;; esac
    printf "%s %s %s\n" "$STORED" "$S" "$RESET"
  ' _ "$@"
}

# Run N consecutive boots from 3/3; echo one "<A> <B> <slot> <reset>" per boot.
boots() {  # <tail.sh> <N> <A loads> <B loads>
  local a=3 b=3 i r sa sb
  for ((i = 1; i <= $2; i++)); do
    r="$(boot "$1" "$a" "$b" "$3" "$4")" || { echo "ERROR"; return 1; }
    read -r sa sb _ _ <<<"$r"
    [[ "$sa" != - ]] && a=$sa; [[ "$sb" != - ]] && b=$sb
    echo "$r"
  done
}

check() {  # <want pass|flag> <tail.sh> <desc> <A loads> <B loads> <N> <expected lines joined by ;>
  local got; ran=$((ran + 1))
  got="$(boots "$2" "$6" "$4" "$5" | paste -sd ';' -)"
  if [[ "$1" == pass ]]; then
    if [[ "$got" == "$7" ]]; then ok "$3"; else bad "$3 — want [$7] got [$got]"; fi
  else
    if [[ "$got" != "$7" ]]; then ok "flagged: $3 [$got]"; else bad "mutation NOT flagged: $3"; fi
  fi
}

extract "$USH" "$W/live.sh" || exit 1

# expected sequences: "<stored A> <stored B> <slot> <reset>" per boot
# Both kernels unreadable: each boot spends one attempt per slot (3 -> 2 -> 1
# -> 0); the boot that spends the last one finds both exhausted and re-arms.
BOTH_FAIL="2 2 - 1;1 1 - 1;3 3 - 1;2 2 - 1;1 1 - 1"
A_FAILS="2 2 B 0;1 1 B 0;0 0 B 0"
A_LOADS="2 3 A 0;1 3 A 0;0 3 A 0"

echo "── must-pass: the live boot script ──"
check pass "$W/live.sh" "both kernels fail to load: counters go 2,1, re-arm only once both are spent" 0 0 5 "$BOTH_FAIL"
check pass "$W/live.sh" "slot A fails to load: B boots, A's attempt is spent" 0 1 3 "$A_FAILS"
check pass "$W/live.sh" "slot A loads: A boots, B untouched" 1 1 3 "$A_LOADS"
# The pre-fix shape: the live script with the guard around the re-arm removed.
# Built AFTER the live checks, so that a script without the guard (the real
# pre-fix script) is reported by the count-down case above, by name.
ran=$((ran + 1))
if python3 - "$USH" "$W/prefix.ush" <<'PY' && extract "$W/prefix.ush" "$W/prefix.sh"; then
import re, sys
s = open(sys.argv[1]).read()
pat = re.compile(r'\n([ \t]*)if test \$\{BOOT_A_LEFT\} -le 0 && test \$\{BOOT_B_LEFT\} -le 0; then\n'
                 r'((?:.*\n)*?)\1fi\n')
m = list(pat.finditer(s))
if len(m) != 1:
    sys.exit("FATAL: expected one 'both exhausted' guard in the live script, found %d" % len(m))
inner = m[0].group(2)
if "setenv BOOT_A_LEFT 3" not in inner or "setenv BOOT_B_LEFT 3" not in inner:
    sys.exit("FATAL: the guard no longer wraps the re-arm")
s = s[:m[0].start()] + "\n" + inner + s[m[0].end():]
open(sys.argv[2], "w").write(s)
PY
  ok "the live script carries the 'both exhausted' guard"
  echo "── must-flag: the pre-fix shape (guard removed) ──"
  check flag "$W/prefix.sh" "both kernels fail to load: pre-fix re-arms 3/3 on every boot" 0 0 5 "$BOTH_FAIL"
  # The mutation must be caught by the count-down case only — the boots that
  # load a kernel behave the same before and after the fix.
  check pass "$W/prefix.sh" "(control) pre-fix, slot A fails to load: unchanged behaviour" 0 1 3 "$A_FAILS"
  check pass "$W/prefix.sh" "(control) pre-fix, slot A loads: unchanged behaviour" 1 1 3 "$A_LOADS"

else
  bad "the live script has no 'both exhausted' guard around the re-arm — the must-flag mutation cannot be built"
fi
echo
[[ "$ran" -ge 4 ]] || { echo "${RED}only $ran cases ran — refusing a verdict${NC}"; exit 1; }
if [[ "$fails" -eq 0 ]]; then echo "${GRN}all $ran cases passed${NC}"; exit 0; fi
echo "${RED}$fails of $ran cases failed${NC}"; exit 1
