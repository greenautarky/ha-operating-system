#!/usr/bin/env bash
# =============================================================================
# selftest.sh — no image leaves the build without a NetBird setup key
# =============================================================================
# Drives the LIVE post-build hook (post-build.d/88-netbird-setup-key.sh) in
# both of its modes against fixture key files, then asks the LIVE build gate
# (run_build_tests.sh, NB-REG-05) what it thinks of the resulting image tree.
#
#   must-fail: key file missing, empty, comments only — the hook and the
#              preflight refuse; an image tree without the key (or with an
#              empty one) is red at NB-REG-05.
#   must-pass: a key file with one real line (comments around it allowed) —
#              the hook bakes it 0600, and NB-REG-05 is green.
#
# Also asserts ga_build.sh really calls the hook's --check in its preflight: a
# tested check the build never runs is decoration.
#
# The key is a throwaway fake; no output here ever prints a key value.
# Offline, no build, a few seconds.
# -----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
HOOK="$ROOT/buildroot-ihost/board/sonoff/ihost/post-build.d/88-netbird-setup-key.sh"
RUNNER="$ROOT/tests/ga_tests/run_build_tests.sh"
BUILD="$ROOT/scripts/ga_build.sh"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=''; GRN=''; NC=''; }
fails=0; ran=0
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$NC" "$*"; fails=$((fails + 1)); }
ok()  { printf '  %sok%s    %s\n' "$GRN" "$NC" "$*"; }
for f in "$HOOK" "$RUNNER" "$BUILD"; do
  [[ -r "$f" ]] || { echo "FATAL: $f missing"; exit 1; }
done

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
FAKE="00000000-0000-4000-8000-000000000000"   # not a real key

# keyfile <name> <content|->  -> path ('-' = file absent)
keyfile() { local p="$W/key-$1.txt"; [[ "$2" != "-" ]] && printf '%b' "$2" > "$p"; printf '%s' "$p"; }
# image <name> -> OUT dir with an empty target/
image() { local d="$W/img-$1"; mkdir -p "$d/target"; printf '%s' "$d"; }

# expect <refuse|accept> <desc> <why-regex|-> -- <cmd...>
# A refusal counts only for the RIGHT reason: <why> must be in the output.
expect() {
  local want="$1" desc="$2" why="$3"; shift 4
  ran=$((ran + 1)); local rc=0; "$@" >"$W/out" 2>&1 || rc=$?
  if grep -qF "$FAKE" "$W/out"; then bad "$desc — output printed the key value"; return; fi
  if [[ "$want" == refuse ]]; then
    if (( rc == 0 )); then bad "$desc — ACCEPTED (rc=0)"; return; fi
    grep -qE -- "$why" "$W/out" || { bad "$desc — refused, but not for '$why': $(head -1 "$W/out")"; return; }
  else
    (( rc == 0 )) || { bad "$desc — refused (rc=$rc): $(head -1 "$W/out")"; return; }
  fi
  ok "$desc"
}
hook()  { NETBIRD_SETUP_KEY_FILE="$1" bash "$HOOK" "$2/target"; }
check() { NETBIRD_SETUP_KEY_FILE="$1" bash "$HOOK" --check; }
verdict() {
  local line; line="$(GA_SRC_ROOT="$ROOT" bash "$RUNNER" "$1" 2>&1 | grep -E "  (PASS|FAIL|SKIP)  NB-REG-05" | head -1)"
  case "$line" in *"  PASS  "*) echo PASS ;; *"  FAIL  "*) echo FAIL ;; *"  SKIP  "*) echo SKIP ;; *) echo ABSENT ;; esac
}
expect_gate() { ran=$((ran + 1)); local got; got="$(verdict "$2")"
  [[ "$got" == "$1" ]] && ok "NB-REG-05 $1 — $3" || bad "NB-REG-05 → got $got, want $1 — $3"; }

MISSING="$(keyfile missing -)"
EMPTY="$(keyfile empty '')"
BLANK="$(keyfile blank '\n  \n\t\n')"
COMMENTS="$(keyfile comments '# NetBird setup key goes below\n\n   # still a comment\n')"
GOOD="$(keyfile good "# reusable key\n\n  ${FAKE}  \n")"

echo "── must-fail: the preflight (--check) refuses ──"
expect refuse "--check: key file missing"        'not found'          -- check "$MISSING"
expect refuse "--check: key file empty"          'no usable key line' -- check "$EMPTY"
expect refuse "--check: blank lines only"        'no usable key line' -- check "$BLANK"
expect refuse "--check: comments only"           'no usable key line' -- check "$COMMENTS"

echo "── must-fail: the post-build hook refuses, and leaves no key behind ──"
for c in MISSING EMPTY COMMENTS; do
  d="$(image "hook-$c")"
  # a key left over from a previous build must not survive a failed read
  mkdir -p "$d/target/usr/share/ga-netbird"; echo stale > "$d/target/usr/share/ga-netbird/setup-key"
  expect refuse "hook: key file ${c,,}" 'FAIL' -- hook "${!c}" "$d"
  ran=$((ran + 1))
  [[ ! -e "$d/target/usr/share/ga-netbird/setup-key" ]] && ok "hook: stale key removed after refusal (${c,,})" \
    || bad "hook: a stale key survived a refused build (${c,,})"
done

echo "── must-fail: the build gate is red on an image without a usable key ──"
d="$(image nokey)"; expect_gate FAIL "$d" "image tree without setup-key"
d="$(image emptykey)"; mkdir -p "$d/target/usr/share/ga-netbird"
: > "$d/target/usr/share/ga-netbird/setup-key"; chmod 600 "$d/target/usr/share/ga-netbird/setup-key"
expect_gate FAIL "$d" "image tree with an EMPTY setup-key"

echo "── must-pass: a real key line is accepted, baked 0600, and the gate is green ──"
expect accept "--check: one key line among comments" - -- check "$GOOD"
d="$(image good)"
expect accept "hook: one key line among comments" - -- hook "$GOOD" "$d"
k="$d/target/usr/share/ga-netbird/setup-key"
ran=$((ran + 1))
if [[ -f "$k" && "$(stat -c '%a' "$k")" == 600 && "$(cat "$k")" == "$FAKE" ]]; then
  ok "hook: key baked 0600, whitespace and comments stripped"
else bad "hook: baked key missing, wrong mode, or not exactly the key line"; fi
expect_gate PASS "$d" "image tree the hook produced"

echo "── wiring: ga_build.sh runs the check in its preflight ──"
ran=$((ran + 1))
if grep -qE '88-netbird-setup-key\.sh' "$BUILD" \
   && grep -A3 -E '^if ! bash "\$GA_NB_KEY_HOOK" --check' "$BUILD" | grep -q 'PREFLIGHT_FAIL=1'; then
  ok "ga_build.sh preflight calls the hook's --check and fails on it"
else bad "ga_build.sh does not run the setup-key --check fail-closed in its preflight"; fi
ran=$((ran + 1))
if grep -qE 'WARN: .*netbird-setup-key' "$BUILD"; then bad "ga_build.sh still carries the warn-only setup-key line"
else ok "no warn-only setup-key fallback left in ga_build.sh"; fi

echo
if (( ran < 18 )); then echo "${RED}FAIL${NC}  only $ran cases ran — expected at least 18"; exit 1; fi
if (( fails > 0 )); then echo "${RED}${fails} of ${ran} case(s) failed${NC}"; exit 1; fi
echo "${GRN}all ${ran} cases passed${NC}"
