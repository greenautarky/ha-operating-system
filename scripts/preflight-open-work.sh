#!/usr/bin/env bash
# =============================================================================
# preflight-open-work.sh — what is finished, or nearly finished, that THIS bake
# will not contain?
# =============================================================================
# A bake turns the current pins into an image. Nothing in that process looks at
# what is waiting next to it: a pin change sitting in an open PR, or an add-on
# that was released and never pinned. Both are invisible in a green build, and
# both mean the image is missing work somebody already paid for.
#
# Two blockers, both measured, neither a matter of taste:
#
#   B1  an open, non-draft PR on this repo that touches a PIN FILE. Those files
#       decide what goes into the image, so a pin waiting in a PR is a decision
#       that has been made and not applied.
#   B2  a pinned add-on whose repository has a NEWER release than the pin. That
#       is the `sync-downstream` trap: the job reports success, opens a PR in the
#       store, nobody merges it, and the version never reaches a device.
#
# Everything else that is open is PRINTED but does not block — a gate that flags
# everything is overridden by reflex, which is a slower way of having no gate.
#
# FAIL CLOSED ON ZERO. If the query cannot run, this exits 2. "No open PRs" and
# "I could not ask" look identical in a summary and mean opposite things.
#
# Worktrees are deliberately NOT covered here: they exist only on one machine and
# CI cannot see them. `--local` adds them when run from a checkout.
set -euo pipefail

REPO_SELF="${REPO_SELF:-greenautarky/ha-operating-system}"
PIN_FILES_DEFAULT="buildroot-external/package/hassio/addon-images.json buildroot-external/package/hassio/version.yaml"
PIN_FILES="${PIN_FILES:-$PIN_FILES_DEFAULT}"
ACK=0
LOCAL=0

usage() { sed -n '2,30p' "$0"; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --acknowledge) ACK=1; shift ;;
    --local)       LOCAL=1; shift ;;
    -h|--help)     usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done

command -v gh >/dev/null 2>&1 || { echo "::error::gh not available — cannot measure open work"; exit 2; }

blockers=0
echo "== Pre-flight: what is open that this bake will not contain =="
echo

# --- B1: open PRs on this repo that touch a pin file -------------------------
if ! prs=$(gh pr list --repo "$REPO_SELF" --state open --limit 100 \
            --json number,title,isDraft,author,files 2>/dev/null); then
  echo "::error::could not list open PRs on $REPO_SELF — refusing to guess that there are none"
  exit 2
fi
# An empty list is a legitimate answer; an unparseable one is not.
echo "$prs" | jq -e 'type == "array"' >/dev/null 2>&1 || {
  echo "::error::open-PR query returned something that is not a list — refusing"; exit 2; }
n_prs=$(echo "$prs" | jq 'length')
echo "-- open PRs on $REPO_SELF: $n_prs (measured)"

pinhits=$(echo "$prs" | jq -r --arg pins "$PIN_FILES" '
  ($pins | split(" ")) as $p
  | .[] | select(.isDraft | not)
  | select(.author.login != "app/dependabot")
  | . as $pr | (.files // []) | map(.path) as $paths
  | select(any($paths[]; . as $f | $p | index($f)))
  | "#\($pr.number)  \($pr.title)"')
if [[ -n "$pinhits" ]]; then
  echo
  echo "::error::open PRs change what this image would contain (pin files):"
  echo "$pinhits" | sed 's/^/    /'
  blockers=$((blockers+1))
fi

# --- B2: pins vs the published store ----------------------------------------
# NOT reimplemented here. scripts/repin-addons.py --check already runs exactly
# this comparison, joined by the `image:` field — the same notion of "the store
# version" the enforcing check-versions gate uses — and it counts what it
# compared instead of passing over zero entries. Writing a second one would be
# the coupling this project has already paid for three times: two readers of the
# same truth that drift apart. Searching first is norm N39's whole point, and
# that norm has been sitting unlanded in an open PR since 2026-08-25.
echo
echo "-- pins vs the published add-on store (scripts/repin-addons.py --check)"
REPIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/repin-addons.py"
if [[ ! -x "$REPIN" && ! -f "$REPIN" ]]; then
  echo "::error::$REPIN not found — cannot compare pins to the store"
  exit 2
fi
if python3 "$REPIN" --check 2>&1 | sed 's/^/    /'; then
  :
else
  rc=${PIPESTATUS[0]}
  # An exit code behind a pipe is the pipe's exit code; read the real one.
  if [[ "$rc" -ne 0 ]]; then
    echo "::error::pins do not match the published store (repin-addons.py --check exited $rc)"
    blockers=$((blockers+1))
  fi
fi

# --- local half: work that exists on no server -------------------------------
if [[ "$LOCAL" == "1" ]]; then
  echo
  echo "-- local branches that would still change master (merge-tree, not git cherry)"
  base=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/master)
  base_tree=$(git rev-parse "$base^{tree}")
  found=0
  while read -r br; do
    [[ -n "$br" ]] || continue
    if tree=$(git merge-tree --write-tree "$base" "$br" 2>/dev/null); then
      t=$(echo "$tree" | head -1)
      if [[ -n "$(git diff --name-only "$base_tree" "$t")" ]]; then
        echo "    $br"; found=$((found+1))
      fi
    fi
  done < <(git for-each-ref --format='%(refname:short)' refs/heads | grep -v '^master$')
  echo "    ($found branch(es) still carry content; worktrees are local-only and invisible to CI)"
fi

echo
if [[ "$blockers" -gt 0 ]]; then
  if [[ "$ACK" == "1" ]]; then
    echo "::warning::$blockers blocker(s) above were ACKNOWLEDGED — baking anyway, on purpose"
    exit 0
  fi
  echo "REFUSING: $blockers blocker(s). Land them, or re-run with --acknowledge to bake without them."
  exit 1
fi
echo "OK: nothing open that this bake would silently leave out."
