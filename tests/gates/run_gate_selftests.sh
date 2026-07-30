#!/usr/bin/env bash
# run_gate_selftests.sh — prove every CI gate can go BOTH red and green.
#
# WHY THIS EXISTS
# ---------------
# Writing a guard and proving a guard are two different activities, and it is
# very easy to do the first while believing you did the second. On 2026-07-30
# an adversarial re-read of one day's new guards found that several could not
# fail at all:
#
#   * a disclosure override placed in a later `if: failure()` step — a failed
#     step fails the job whatever runs after it, so the override was decoration
#   * a dev/prod signing selector keyed on a variable that is hardcoded and
#     never differs between the two modes, so the separation was inert
#   * the disclosure gate itself scanned only the diff, and the incident that
#     motivated it went through commit messages — it scored zero on its own
#     corpus
#
# None of that is visible in review, and none of it is visible in a green run.
# The only thing that finds it is running the gate against inputs whose correct
# verdict is known in advance.
#
# The norm (N1 / rule 6) already said "paste the failing output into the PR".
# A paste is evidence once. This turns the same evidence into a test that runs
# on every PR forever, so a gate cannot silently rot into decoration.
#
# HOW IT WORKS
# ------------
# Each gate has a fixture directory:
#
#   tests/gates/<gate>/must-fail/*.txt   the gate MUST flag these
#   tests/gates/<gate>/must-pass/*.txt   the gate must NOT flag these
#
# must-pass is not padding. A gate that flags everything is as useless as one
# that flags nothing, and it is worse in practice: it trains people to reach
# for the override without reading. Every documented false positive that was
# ever fixed belongs in must-pass so it cannot come back.
#
# CRITICAL: the patterns are READ OUT OF THE WORKFLOW, never copied here. A
# self-test that re-declares the patterns tests a copy — it stays green while
# the real gate rots, which is precisely the failure class this file exists to
# catch. If the extraction ever stops finding them, that is a failure, not a
# skip.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW="${REPO_ROOT}/.github/workflows/disclosure-check.yml"

GREEN='\033[0;32m' RED='\033[0;31m' RESET='\033[0m'
[[ -t 1 ]] || { GREEN=''; RED=''; RESET=''; }

pass=0 fail=0
_ok()   { pass=$((pass+1)); printf "  ${GREEN}ok${RESET}    %s\n" "$1"; }
_bad()  { fail=$((fail+1)); printf "  ${RED}FAIL${RESET}  %s\n" "$1"; }

# --- extract the live patterns -------------------------------------------
[[ -f "$WORKFLOW" ]] || { echo "ERROR: $WORKFLOW not found — cannot self-test" >&2; exit 2; }

# Only the variable assignments, taken verbatim from the workflow so there is
# exactly one definition of each pattern in the repository.
_defs="$(grep -E "^ *(ALLOW|ADDR|OPEN|CRED|PLACEHOLDER)='" "$WORKFLOW" | sed -E 's/^ *//')"
for _v in ALLOW ADDR OPEN CRED PLACEHOLDER; do
  printf '%s\n' "$_defs" | grep -q "^${_v}=" || {
    echo "ERROR: could not extract ${_v} from $(basename "$WORKFLOW")." >&2
    echo "       The gate was restructured and this self-test no longer reads" >&2
    echo "       the real patterns. That is a FAILURE, not a skip: a self-test" >&2
    echo "       that silently tests nothing is worse than none." >&2
    exit 2
  }
done
eval "$_defs"

echo "=== Gate self-test: disclosure-check ==="
echo "patterns read from $(basename "$WORKFLOW") — not copied"
echo

# Same order of operations as the gate: neutralise the allowlisted public
# constants first, then match.
_flags() {
  local f="$1" clean
  clean="$(sed -E "$ALLOW" "$f")"
  local hit=""
  printf '%s\n' "$clean" | grep -qE  -- "$ADDR" && hit+="ADDR "
  printf '%s\n' "$clean" | grep -qiE -- "$OPEN" && hit+="OPEN "
  if printf '%s\n' "$clean" | grep -qiE -- "$CRED"; then
    printf '%s\n' "$clean" | grep -iE -- "$CRED" | grep -qvE -- "$PLACEHOLDER" && hit+="CRED "
  fi
  printf '%s' "$hit"
}

echo "must-fail — the gate has to flag every one of these:"
for f in "${SCRIPT_DIR}"/disclosure/must-fail/*.txt; do
  [[ -f "$f" ]] || continue
  h="$(_flags "$f")"
  if [[ -n "$h" ]]; then _ok "$(basename "$f" .txt)  [${h% }]"
  else _bad "$(basename "$f" .txt) — NOT flagged. The gate does not catch: $(head -1 "$f")"; fi
done

echo
echo "must-pass — flagging any of these would train people to skip the gate:"
for f in "${SCRIPT_DIR}"/disclosure/must-pass/*.txt; do
  [[ -f "$f" ]] || continue
  h="$(_flags "$f")"
  if [[ -z "$h" ]]; then _ok "$(basename "$f" .txt)"
  else _bad "$(basename "$f" .txt) — false positive [${h% }]: $(head -1 "$f")"; fi
done

# A fixture set that shrank to nothing would pass silently.
_nf="$(find "${SCRIPT_DIR}/disclosure/must-fail" -name '*.txt' 2>/dev/null | wc -l)"
_np="$(find "${SCRIPT_DIR}/disclosure/must-pass" -name '*.txt' 2>/dev/null | wc -l)"
if (( _nf == 0 || _np == 0 )); then
  echo
  echo "ERROR: fixture set is empty (must-fail=${_nf} must-pass=${_np}) — nothing was proven." >&2
  exit 2
fi

echo
echo "${pass} ok, ${fail} failed  (${_nf} must-fail, ${_np} must-pass fixtures)"
(( fail == 0 )) || exit 1
echo "Every gate pattern was shown to fire on a known-bad input AND stay quiet on a known-good one."
