#!/bin/bash
# release.sh — Bump versions for a new release, commit, and push.
#
# Updates three places that MUST stay in sync:
#   1. ha-supervisor/supervisor/const.py        SUPERVISOR_VERSION
#   2. haos-version/stable.json                  "supervisor" key
#   3. haos-version/stable.json                  "ihost" key (under hassos)
#
# After this runs, the next steps are MANUAL (intentionally):
#   a. SSH ga-builder, run: ./scripts/ga_build.sh prod
#   b. Locally:    ./scripts/push-ota.sh --server --raucb <bundle>.raucb
#   c. Verify on a canary device, then push-ota --fleet (or wait for auto-pull)
#
# Usage:
#   ./scripts/release.sh <os-version> <supervisor-version> [--dry-run] [--no-push]
#
# Example:
#   ./scripts/release.sh 16.3.1.2 2025.11.4.2
#   ./scripts/release.sh 16.3.1.2 2025.11.4.2 --dry-run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HA_OS_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
SUPERVISOR_REPO="${SUPERVISOR_REPO:-/home/user/git/ha-supervisor}"
HAOS_VERSION_REPO="${HAOS_VERSION_REPO:-/home/user/git/haos-version}"

# haos-version: main is the authoritative branch for ihost (it's what
# URL_HASSIO_VERSION in ha-supervisor const.py points at). DSGW210-specific
# entries live on a separate branch and are not touched by release.sh.
HAOS_VERSION_BRANCH="${HAOS_VERSION_BRANCH:-main}"
SUPERVISOR_BRANCH="${SUPERVISOR_BRANCH:-ga/custom-version-url}"

DRY_RUN=false
NO_PUSH=false
OS_VERSION=""
SUP_VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=true; shift ;;
        --no-push)  NO_PUSH=true; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            if [[ -z "$OS_VERSION" ]]; then
                OS_VERSION="$1"
            elif [[ -z "$SUP_VERSION" ]]; then
                SUP_VERSION="$1"
            else
                echo "ERROR: too many arguments"; exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$OS_VERSION" || -z "$SUP_VERSION" ]]; then
    echo "ERROR: missing version arguments"
    echo "Usage: $0 <os-version> <supervisor-version> [--dry-run] [--no-push]"
    exit 1
fi

# Sanity-check version format
if ! [[ "$OS_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?(\.[0-9]+)?$ ]]; then
    echo "ERROR: OS version '$OS_VERSION' looks malformed (expected N.N.N or N.N.N.N)"
    exit 1
fi
if ! [[ "$SUP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "ERROR: Supervisor version '$SUP_VERSION' looks malformed (expected YYYY.MM.N or YYYY.MM.N.N)"
    exit 1
fi

echo "============================================="
echo "  GA Release Bump"
echo "============================================="
echo "  OS / hassos.ihost:      $OS_VERSION"
echo "  Supervisor:             $SUP_VERSION"
echo "  ha-supervisor branch:   $SUPERVISOR_BRANCH"
echo "  haos-version branch:    $HAOS_VERSION_BRANCH"
$DRY_RUN  && echo "  Mode:                   DRY-RUN"
$NO_PUSH  && echo "  Push:                   DISABLED (--no-push)"
echo ""

# Pre-flight: all three repos must be on expected branch with clean WC
preflight() {
    local repo="$1" branch="$2" name="$3"
    [[ -d "$repo/.git" ]] || { echo "  $name: NOT a git repo at $repo"; return 1; }
    local cur
    cur=$(cd "$repo" && git branch --show-current)
    if [[ "$cur" != "$branch" ]]; then
        echo "  $name: on '$cur', expected '$branch'"
        return 1
    fi
    if ! (cd "$repo" && git diff --quiet && git diff --cached --quiet); then
        echo "  $name: working tree NOT clean — commit or stash first"
        return 1
    fi
    echo "  $name: branch=$cur, clean ✓"
}

echo "Pre-flight checks:"
FAILED=0
preflight "$SUPERVISOR_REPO"     "$SUPERVISOR_BRANCH"     "ha-supervisor"  || FAILED=1
preflight "$HAOS_VERSION_REPO"   "$HAOS_VERSION_BRANCH"   "haos-version"   || FAILED=1
[[ $FAILED -eq 0 ]] || { echo ""; echo "Pre-flight failed — aborting."; exit 1; }
echo ""

# Read current values to show diff
CUR_SUP=$(grep -E '^SUPERVISOR_VERSION' "$SUPERVISOR_REPO/supervisor/const.py" \
    | sed -E 's/.*"([^"]+)".*/\1/')
CUR_OS=$(python3 -c "import json; print(json.load(open('$HAOS_VERSION_REPO/stable.json'))['hassos']['ihost'])")
CUR_SUP_JSON=$(python3 -c "import json; print(json.load(open('$HAOS_VERSION_REPO/stable.json'))['supervisor'])")

echo "Current values:"
echo "  ha-supervisor const.py SUPERVISOR_VERSION = $CUR_SUP"
echo "  haos-version stable.json supervisor       = $CUR_SUP_JSON"
echo "  haos-version stable.json hassos.ihost     = $CUR_OS"
echo ""
echo "Will change to:"
echo "  ha-supervisor const.py SUPERVISOR_VERSION = $SUP_VERSION"
echo "  haos-version stable.json supervisor       = $SUP_VERSION"
echo "  haos-version stable.json hassos.ihost     = $OS_VERSION"
echo ""

# Skip-checks: bail if nothing changed
if [[ "$CUR_SUP" == "$SUP_VERSION" && "$CUR_OS" == "$OS_VERSION" && "$CUR_SUP_JSON" == "$SUP_VERSION" ]]; then
    echo "All three values already match the requested versions — nothing to do."
    exit 0
fi

if $DRY_RUN; then
    echo "[DRY-RUN] No changes made."
    exit 0
fi

# Apply changes -------------------------------------------------------------
echo "Applying ha-supervisor const.py..."
sed -i.bak -E "s|^(SUPERVISOR_VERSION = )\"[^\"]+\"|\1\"$SUP_VERSION\"|" \
    "$SUPERVISOR_REPO/supervisor/const.py"
rm "$SUPERVISOR_REPO/supervisor/const.py.bak"
NEW_SUP=$(grep -E '^SUPERVISOR_VERSION' "$SUPERVISOR_REPO/supervisor/const.py" \
    | sed -E 's/.*"([^"]+)".*/\1/')
[[ "$NEW_SUP" == "$SUP_VERSION" ]] || { echo "  FAIL: const.py edit didn't take"; exit 1; }
echo "  → $NEW_SUP ✓"

echo "Applying haos-version stable.json..."
python3 - <<PY
import json
from collections import OrderedDict
path = "$HAOS_VERSION_REPO/stable.json"
with open(path) as f:
    data = json.load(f, object_pairs_hook=OrderedDict)
data['supervisor'] = "$SUP_VERSION"
data['hassos']['ihost'] = "$OS_VERSION"
# Preserve the 2-space indent style on main (avoids whitespace churn in commit)
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PY
echo "  → supervisor=$SUP_VERSION, hassos.ihost=$OS_VERSION ✓"
echo ""

# Commit + push
commit_repo() {
    local repo="$1" file="$2" subject="$3" branch="$4"
    cd "$repo"
    git add "$file"
    if git diff --cached --quiet; then
        echo "  ($repo): no diff to commit — skipping"
        return 0
    fi
    git commit -m "$subject

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
    if $NO_PUSH; then
        echo "  ($repo): commit made, push skipped (--no-push)"
        return 0
    fi
    git push origin "$branch"
}

echo "Committing + pushing..."
commit_repo "$SUPERVISOR_REPO"   "supervisor/const.py" \
    "chore: bump SUPERVISOR_VERSION to $SUP_VERSION"   "$SUPERVISOR_BRANCH"
commit_repo "$HAOS_VERSION_REPO" "stable.json" \
    "release: ihost $OS_VERSION + supervisor $SUP_VERSION" "$HAOS_VERSION_BRANCH"

echo ""
echo "============================================="
echo "  Versions bumped + pushed ✓"
echo "============================================="
echo ""
echo "Next steps (manual):"
echo "  1. Build on ga-builder:"
echo "       ssh ga-builder 'cd /home/lxc/ha-operating-system && git pull && ./scripts/ga_build.sh prod'"
echo "  2. Copy bundle back, then upload to ga-tools:"
echo "       ./scripts/push-ota.sh --server --raucb releases/.../haos_ihost-$OS_VERSION.raucb"
echo "  3. Canary verify (single device):"
echo "       ssh -p 22222 root@<one-device> 'ha core update --version $SUP_VERSION'"
echo ""
