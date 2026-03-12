#!/usr/bin/env bash
# Unified test orchestrator for GA OS, Frontend, and Core repos.
#
# Usage:
#   ./tests/test-all.sh                     # source + CI status (default)
#   ./tests/test-all.sh --level source      # local OS tests + CI status
#   ./tests/test-all.sh --level build       # post-build tests (needs build output)
#   ./tests/test-all.sh --level device      # device tests (needs SSH/serial)
#   ./tests/test-all.sh --level all         # all three in sequence
#   ./tests/test-all.sh --local             # also run local frontend/core tests
#
# Environment variables:
#   FRONTEND_ROOT   Path to frontend repo (default: ~/git/homeassistant_frontend)
#   CORE_ROOT       Path to core repo (default: ~/git/homeassisant_core)
#   REPO_ROOT       Path to OS repo (default: auto-detected)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FRONTEND_ROOT="${FRONTEND_ROOT:-$HOME/git/homeassistant_frontend}"
CORE_ROOT="${CORE_ROOT:-$HOME/git/homeassisant_core}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
total_pass=0
total_fail=0
total_skip=0

# Parse arguments
LEVEL="source"
LOCAL=false
PASSTHROUGH_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --level)
            LEVEL="$2"
            shift 2
            ;;
        --local)
            LOCAL=true
            shift
            ;;
        *)
            PASSTHROUGH_ARGS+=("$1")
            shift
            ;;
    esac
done

_pass() {
    printf "  ${GREEN}PASS${NC}  %s\n" "$1"
    total_pass=$((total_pass + 1))
}

_fail() {
    printf "  ${RED}FAIL${NC}  %s\n" "$1"
    total_fail=$((total_fail + 1))
}

_skip() {
    printf "  ${YELLOW}SKIP${NC}  %s: %s\n" "$1" "$2"
    total_skip=$((total_skip + 1))
}

_section() {
    printf "\n${BLUE}--- %s ---${NC}\n" "$1"
}

# ---------------------------------------------------------------------------
# Section A: OS source-level tests
# ---------------------------------------------------------------------------
run_os_source_tests() {
    _section "OS: source-level tests (SRC/VER/XVER)"

    local test_script="$REPO_ROOT/tests/ga_tests/run_build_tests.sh"
    if [[ ! -f "$test_script" ]]; then
        _skip "OS-SRC" "run_build_tests.sh not found"
        return
    fi

    local output
    output=$(REPO_ROOT="$REPO_ROOT" FRONTEND_ROOT="${FRONTEND_ROOT:-}" bash "$test_script" 2>&1) || true

    # Count results from the test output
    local pass_count fail_count skip_count
    pass_count=$(echo "$output" | grep -cE '^\s*PASS' || true)
    fail_count=$(echo "$output" | grep -cE '^\s*FAIL' || true)
    skip_count=$(echo "$output" | grep -cE '^\s*SKIP' || true)

    # Only count source-level failures (SRC/VER/XVER), not build-only tests
    local src_fails
    src_fails=$(echo "$output" | grep -E '^\s*FAIL' | grep -v 'BLD-\|REG-\|DT-\|CFG-\|ENV-\|CRASH-\|SD-\|DG-' || true)

    if [[ -n "$src_fails" ]]; then
        echo "$src_fails"
        local src_fail_count
        src_fail_count=$(echo "$src_fails" | wc -l)
        _fail "OS source tests: $src_fail_count failure(s)"
    else
        _pass "OS source tests: $pass_count passed, $skip_count skipped (build-only tests excluded)"
    fi
}

# ---------------------------------------------------------------------------
# Section B: Image availability
# ---------------------------------------------------------------------------
run_image_check() {
    _section "Image availability (GHCR)"

    local check_script="$REPO_ROOT/scripts/check-images.sh"
    if [[ ! -f "$check_script" ]]; then
        _skip "IMG" "check-images.sh not found"
        return
    fi

    if bash "$check_script" >/dev/null 2>&1; then
        _pass "All container images available in registries"
    else
        _fail "Some container images missing — run: ./scripts/check-images.sh"
    fi
}

# ---------------------------------------------------------------------------
# Section C: CI status checks via gh CLI
# ---------------------------------------------------------------------------
check_ci_status() {
    local repo="$1"
    local workflow="$2"
    local branch="$3"
    local label="$4"

    local result
    result=$(gh run list \
        --repo "$repo" \
        --workflow "$workflow" \
        --branch "$branch" \
        --limit 1 \
        --json status,conclusion \
        2>/dev/null) || { _skip "$label" "gh query failed"; return; }

    local status conclusion
    status=$(echo "$result" | jq -r '.[0].status // "unknown"')
    conclusion=$(echo "$result" | jq -r '.[0].conclusion // "unknown"')

    if [[ "$status" == "completed" && "$conclusion" == "success" ]]; then
        _pass "$label: CI passed ($repo)"
    elif [[ "$status" == "in_progress" ]]; then
        _skip "$label" "CI in progress ($repo)"
    elif [[ "$status" == "null" || "$status" == "unknown" ]]; then
        _skip "$label" "no CI runs found ($repo)"
    else
        _fail "$label: CI $conclusion ($repo)"
    fi
}

run_ci_checks() {
    _section "CI status (GitHub Actions)"

    if ! command -v gh >/dev/null 2>&1; then
        _skip "CI" "gh CLI not installed"
        return
    fi

    if ! gh auth status >/dev/null 2>&1; then
        _skip "CI" "gh not authenticated"
        return
    fi

    check_ci_status \
        "greenautarky/ha-operating-system" \
        "Version Chain Check" \
        "master" \
        "CI-OS"

    check_ci_status \
        "thomas-greenautarky/frontend" \
        "CI" \
        "ga/custom-onboarding" \
        "CI-FE"

    check_ci_status \
        "greenautarky/ha-core" \
        "Build greenautarky HA Core image" \
        "ga/custom-onboarding" \
        "CI-CORE"
}

# ---------------------------------------------------------------------------
# Section D: Local repo tests (optional, --local flag)
# ---------------------------------------------------------------------------
run_local_frontend_tests() {
    _section "Frontend: local tests (vitest)"

    if [[ ! -d "$FRONTEND_ROOT" ]]; then
        _skip "FE-LOCAL" "frontend repo not found at $FRONTEND_ROOT"
        return
    fi

    if [[ ! -f "$FRONTEND_ROOT/package.json" ]]; then
        _skip "FE-LOCAL" "no package.json in $FRONTEND_ROOT"
        return
    fi

    local output
    if (cd "$FRONTEND_ROOT" && yarn test --run 2>&1) >/dev/null 2>&1; then
        _pass "Frontend vitest: all tests passed"
    else
        _fail "Frontend vitest: tests failed — run: cd $FRONTEND_ROOT && yarn test"
    fi
}

run_local_core_tests() {
    _section "Core: local tests (pytest)"

    if [[ ! -d "$CORE_ROOT" ]]; then
        _skip "CORE-LOCAL" "core repo not found at $CORE_ROOT"
        return
    fi

    local test_dir="$CORE_ROOT/tests/components/greenautarky_onboarding"
    local tel_dir="$CORE_ROOT/tests/components/greenautarky_telemetry"

    if [[ ! -d "$test_dir" ]]; then
        _skip "CORE-LOCAL" "greenautarky_onboarding tests not found"
        return
    fi

    local targets="$test_dir"
    [[ -d "$tel_dir" ]] && targets="$targets $tel_dir"

    if (cd "$CORE_ROOT" && python -m pytest $targets -q 2>&1) >/dev/null 2>&1; then
        _pass "Core pytest: all GA tests passed"
    else
        _fail "Core pytest: tests failed — run: cd $CORE_ROOT && python -m pytest $targets -v"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo ""
echo "=== GA Test Orchestrator ==="
echo "  Level: $LEVEL"
echo "  Local: $LOCAL"
echo "  OS repo: $REPO_ROOT"
[[ "$LOCAL" == true ]] && echo "  Frontend: $FRONTEND_ROOT"
[[ "$LOCAL" == true ]] && echo "  Core: $CORE_ROOT"

case "$LEVEL" in
    source)
        run_os_source_tests
        run_image_check
        run_ci_checks
        if [[ "$LOCAL" == true ]]; then
            run_local_frontend_tests
            run_local_core_tests
        fi
        ;;
    build)
        _section "Build tests (delegating to run_build_tests.sh)"
        exec "$SCRIPT_DIR/ga_tests/run_build_tests.sh" "${PASSTHROUGH_ARGS[@]}"
        ;;
    device)
        _section "Device tests (delegating to run_device_tests.sh)"
        exec "$SCRIPT_DIR/run_device_tests.sh" "${PASSTHROUGH_ARGS[@]}"
        ;;
    all)
        run_os_source_tests
        run_image_check
        run_ci_checks
        if [[ "$LOCAL" == true ]]; then
            run_local_frontend_tests
            run_local_core_tests
        fi
        # Build and device tests need explicit args — just run source level for "all"
        echo ""
        printf "${YELLOW}NOTE${NC}: build and device tests require additional args.\n"
        echo "  Build: ./tests/test-all.sh --level build"
        echo "  Device: ./tests/test-all.sh --level device --ssh root@<ip>"
        ;;
    *)
        echo "ERROR: Unknown level '$LEVEL'. Use: source, build, device, all" >&2
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
printf "  ${GREEN}Passed${NC}: %d\n" "$total_pass"
printf "  ${RED}Failed${NC}: %d\n" "$total_fail"
printf "  ${YELLOW}Skipped${NC}: %d\n" "$total_skip"

if [[ "$total_fail" -gt 0 ]]; then
    echo ""
    printf "${RED}%d test(s) failed.${NC}\n" "$total_fail"
    exit 1
else
    echo ""
    printf "${GREEN}All checks passed.${NC}\n"
    exit 0
fi
