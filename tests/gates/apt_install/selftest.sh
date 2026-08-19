#!/usr/bin/env bash
# =============================================================================
# selftest.sh — prove .github/actions/apt-install turns a HANG into a failure.
# =============================================================================
# WHY, in one paragraph: on 2026-08-18/19 `check-versions` could not report on a
# pull request at all. Three runs wedged in `apt-get install -y -qq jq skopeo` —
# one for 21m57s, one for roughly SIXTEEN HOURS — while the pull request's diff
# was a single line in addon-images.json. A required check that cannot report is a
# deadlock, and three of this repo's gates fetch their own tooling from an apt
# mirror at run time.
#
# The part that matters is the TIMEOUT, not the retry: a retry does nothing about
# a hang, because the hung call never returns. So that is what this asserts first.
#
# The script under test is EXTRACTED FROM action.yml, never copied here. A
# self-test that re-declares the logic tests its own copy, stays green while the
# action rots, and is the exact failure class this repo keeps paying for. If the
# extraction stops finding the script, this FAILS — it does not skip.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
ACTION="$ROOT/.github/actions/apt-install/action.yml"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; NC=$'\033[0m'
fails=0; ran=0

bad() { printf '  %sFAIL%s  %s\n' "$RED" "$NC" "$*"; fails=$((fails + 1)); }
ok()  { printf '  %sok%s    %s\n' "$GRN" "$NC" "$*"; }

[[ -f "$ACTION" ]] || { echo "FATAL: $ACTION missing"; exit 1; }

# --- extract the live script -------------------------------------------------
# The action has exactly one composite step whose `run: |` block is the logic.
# python3 reads the YAML rather than guessing indentation, so a reformat of the
# file cannot silently truncate what we test.
SCRIPT="$(python3 - "$ACTION" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
runs = [s.get("run") for s in d["runs"]["steps"] if s.get("run")]
if len(runs) != 1:
    sys.exit(f"expected exactly one run: block, found {len(runs)}")
sys.stdout.write(runs[0])
PY
)" || { echo "${RED}FAIL${NC}  could not extract the script from action.yml — fix the extraction, do not skip"; exit 1; }

if [[ ${#SCRIPT} -lt 200 ]]; then
    echo "${RED}FAIL${NC}  extracted script is only ${#SCRIPT} chars — the extraction has drifted"
    exit 1
fi

# --- harness -----------------------------------------------------------------
# A fake `sudo` on PATH is what makes this testable without root, without apt and
# without a network. Each case decides how `sudo apt-get …` behaves.
run_case() { # run_case <label> <expect-rc> <packages> <sudo-body> [timeout] [attempts]
    local label="$1" want="$2" pkgs="$3" body="$4" tmo="${5:-2}" att="${6:-2}"
    local dir out rc
    dir="$(mktemp -d)"
    printf '#!/usr/bin/env bash\n%s\n' "$body" > "$dir/sudo"
    chmod +x "$dir/sudo"
    ran=$((ran + 1))
    # No pipe around the run: an exit code read through a pipe is the pipe's.
    out="$(PATH="$dir:$PATH" PACKAGES="$pkgs" TIMEOUT_S="$tmo" ATTEMPTS="$att" \
           bash -c "$SCRIPT" 2>&1)"; rc=$?
    rm -rf "$dir"
    if [[ "$rc" -eq "$want" ]]; then
        ok "$label (rc=$rc)"
        printf '%s' "$out" > /tmp/.apt_selftest_last
        return 0
    fi
    bad "$label — rc=$rc, expected $want"
    printf '%s\n' "$out" | sed 's/^/          /'
    printf '%s' "$out" > /tmp/.apt_selftest_last
    return 1
}

expect_output() { # expect_output <needle> <label>
    ran=$((ran + 1))
    if grep -qF "$1" /tmp/.apt_selftest_last; then ok "$2"; else
        bad "$2 — output did not contain '$1'"
        sed 's/^/          /' /tmp/.apt_selftest_last
    fi
}

echo "== a HANG must become a failure, not a wedged job =="
# This is the 2026-08-19 defect verbatim: apt never returns. Without `timeout`
# the job runs until the workflow is killed, which is how a check spends 16 hours
# reporting nothing.
run_case "apt hangs -> bounded, then fails" 1 "definitely-not-installed-xyz" \
    'sleep 300' 2 2
expect_output "TIMED OUT" "says it timed out, so the cause is readable"
expect_output "::error::" "annotates, so the failure shows on the run"

echo "== a transient failure must be retried =="
run_case "fails once, then succeeds" 0 "definitely-not-installed-xyz" \
    'f=/tmp/.apt_selftest_count
     n=$(cat "$f" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$f"
     # apt-get update is called first in every attempt; count only installs
     case "$*" in *install*) [ "$n" -ge 2 ] || exit 100 ;; esac
     # make the package appear on PATH so the final verification passes
     d=$(dirname "$(command -v sudo)")
     printf "#!/bin/sh\necho stub\n" > "$d/definitely-not-installed-xyz"
     chmod +x "$d/definitely-not-installed-xyz"
     exit 0' 5 3
rm -f /tmp/.apt_selftest_count

echo "== work already done must not be repeated =="
run_case "package already present -> no apt at all" 0 "bash" \
    'echo "APT WAS CALLED — it should not have been"; exit 1' 5 2
expect_output "nothing to install" "says so, so a needless install is visible in the log"

echo "== an install that leaves nothing on PATH is a false green =="
# The shape this guard exists for: apt exits 0, the tool is absent, and the gate
# would otherwise run without its tooling and report a clean result.
run_case "apt succeeds but the tool is missing -> fail" 1 "definitely-not-installed-xyz" \
    'exit 0' 5 2
expect_output "still not on PATH" "names the false-green case"

echo
if (( ran == 0 )); then
    echo "${RED}FATAL${NC}  nothing evaluated"
    exit 1
fi
if (( fails == 0 )); then
    printf '%sapt-install selftest: %d/%d%s\n' "$GRN" "$ran" "$ran" "$NC"
    exit 0
fi
printf '%sapt-install selftest: %d of %d FAILED%s\n' "$RED" "$fails" "$ran" "$NC"
exit 1
