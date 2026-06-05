#!/bin/bash
# release.sh — Bump versions for a new release, commit, and push.
#
# Updates four places that MUST stay in sync:
#   1. ha-supervisor/supervisor/const.py        SUPERVISOR_VERSION
#   2. haos-version/stable.json                  "supervisor" key
#   3. haos-version/stable.json                  "ihost" key (under hassos)
#   4. haos-version/stable.json                  "ga_release" key  (new since v1.2)
#
# After this runs, the next steps are MANUAL (intentionally):
#   a. SSH ga-builder, run: GA_RELEASE=<ga-release> ./scripts/ga_build.sh prod
#   b. Locally:    ./scripts/push-ota.sh --server --raucb <bundle>.raucb
#   c. Verify on a canary device, then push-ota --fleet (or wait for auto-pull)
#
# Usage:
#   ./scripts/release.sh <os-version> <supervisor-version> [--ga-release VAR] [--dry-run] [--no-push]
#
# Examples:
#   # Plain HAOS-version bump (legacy form — keeps current ga_release):
#   ./scripts/release.sh 16.3.1.2 2025.11.4.2
#
#   # Full BOSv1.x.y release (preferred since v1.2):
#   ./scripts/release.sh 16.3.1.2 2025.11.4.5 --ga-release BOSv1.2.1
#
#   # Dry-run preview:
#   ./scripts/release.sh 16.3.1.2 2025.11.4.5 --ga-release BOSv1.2.1 --dry-run
#
# Why --ga-release: BOSv1.2.0 and BOSv1.2.1 share the same internal HAOS
# version (16.3.1.2) but differ in the OS rootfs overlay. The ga_release
# label is the operator-facing identifier (the one stamped into
# /etc/ga-release on the device); without bumping it here, every BOSv1.x.y
# point-release silently overwrites the previous release's manifest with
# the same hassos.ihost — fleet-manager OTA jobs then no-op because
# Supervisor's no-op-check matches the running HAOS version.
# See [[session_2026_06_04_fleet_ota_findings]] finding #3.

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
GA_RELEASE=""  # optional; if unset we preserve whatever is in stable.json

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)     DRY_RUN=true; shift ;;
        --no-push)     NO_PUSH=true; shift ;;
        --ga-release)  GA_RELEASE="$2"; shift 2 ;;
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

# Sanity-check the ga_release label format if supplied. The convention
# (since 2026-06-02) is BOSvMAJOR.MINOR.PATCH (e.g. BOSv1.2.1).
if [[ -n "$GA_RELEASE" ]] && ! [[ "$GA_RELEASE" =~ ^BOSv[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: ga_release '$GA_RELEASE' looks malformed (expected BOSvMAJOR.MINOR.PATCH)"
    exit 1
fi

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
[[ -n "$GA_RELEASE" ]] && echo "  GA Release label:       $GA_RELEASE"
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
preflight "$HA_OS_REPO"          "master"                 "ha-operating-system" || FAILED=1
[[ $FAILED -eq 0 ]] || { echo ""; echo "Pre-flight failed — aborting."; exit 1; }
echo ""

# Read current values to show diff
META_FILE="$HA_OS_REPO/buildroot-external/meta"
CUR_SUP=$(grep -E '^SUPERVISOR_VERSION' "$SUPERVISOR_REPO/supervisor/const.py" \
    | sed -E 's/.*"([^"]+)".*/\1/')
CUR_OS=$(python3 -c "import json; print(json.load(open('$HAOS_VERSION_REPO/stable.json'))['hassos']['ihost'])")
CUR_SUP_JSON=$(python3 -c "import json; print(json.load(open('$HAOS_VERSION_REPO/stable.json'))['supervisor'])")
CUR_GA_REL=$(python3 -c "import json; print(json.load(open('$HAOS_VERSION_REPO/stable.json')).get('ga_release',''))")
# Reconstruct OS version from meta (VERSION_MAJOR + VERSION_MINOR + VERSION_SUFFIX)
META_MAJOR=$(grep '^VERSION_MAJOR=' "$META_FILE" | cut -d'"' -f2)
META_MINOR=$(grep '^VERSION_MINOR=' "$META_FILE" | cut -d'"' -f2)
META_SUFFIX=$(grep '^VERSION_SUFFIX=' "$META_FILE" | cut -d'"' -f2)
CUR_META_OS="${META_MAJOR}.${META_MINOR}.${META_SUFFIX}"

# Compute target meta values from requested OS_VERSION (e.g. 16.3.1.2 → MAJOR=16, MINOR=3, SUFFIX=1.2)
NEW_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)
NEW_MINOR=$(echo "$OS_VERSION" | cut -d. -f2)
NEW_SUFFIX=$(echo "$OS_VERSION" | cut -d. -f3-)

echo "Current values:"
echo "  ha-supervisor const.py SUPERVISOR_VERSION = $CUR_SUP"
echo "  haos-version stable.json supervisor       = $CUR_SUP_JSON"
echo "  haos-version stable.json hassos.ihost     = $CUR_OS"
echo "  haos-version stable.json ga_release       = $CUR_GA_REL"
echo "  buildroot-external/meta OS-version        = $CUR_META_OS"
echo ""
echo "Will change to:"
echo "  ha-supervisor const.py SUPERVISOR_VERSION = $SUP_VERSION"
echo "  haos-version stable.json supervisor       = $SUP_VERSION"
echo "  haos-version stable.json hassos.ihost     = $OS_VERSION"
if [[ -n "$GA_RELEASE" ]]; then
    echo "  haos-version stable.json ga_release       = $GA_RELEASE"
else
    echo "  haos-version stable.json ga_release       = (unchanged: $CUR_GA_REL)"
fi
echo "  buildroot-external/meta OS-version        = $OS_VERSION (MAJOR=$NEW_MAJOR MINOR=$NEW_MINOR SUFFIX=$NEW_SUFFIX)"
echo ""

# Skip-checks: bail if nothing changed
EFFECTIVE_GA_REL="${GA_RELEASE:-$CUR_GA_REL}"
if [[ "$CUR_SUP" == "$SUP_VERSION" && "$CUR_OS" == "$OS_VERSION" \
      && "$CUR_SUP_JSON" == "$SUP_VERSION" && "$CUR_META_OS" == "$OS_VERSION" \
      && "$CUR_GA_REL" == "$EFFECTIVE_GA_REL" ]]; then
    echo "All values already match the requested versions — nothing to do."
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
GA_RELEASE_ARG="$GA_RELEASE" python3 - <<PY
import json, os
from collections import OrderedDict
path = "$HAOS_VERSION_REPO/stable.json"
with open(path) as f:
    data = json.load(f, object_pairs_hook=OrderedDict)
data['supervisor'] = "$SUP_VERSION"
data['hassos']['ihost'] = "$OS_VERSION"
ga_release = os.environ.get("GA_RELEASE_ARG", "")
if ga_release:
    data['ga_release'] = ga_release
# Preserve the 2-space indent style on main (avoids whitespace churn in commit)
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PY
if [[ -n "$GA_RELEASE" ]]; then
    echo "  → supervisor=$SUP_VERSION, hassos.ihost=$OS_VERSION, ga_release=$GA_RELEASE ✓"
else
    echo "  → supervisor=$SUP_VERSION, hassos.ihost=$OS_VERSION (ga_release unchanged) ✓"
fi

echo "Applying buildroot-external/meta..."
sed -i.bak -E "s|^VERSION_MAJOR=.*|VERSION_MAJOR=\"$NEW_MAJOR\"|" "$META_FILE"
sed -i.bak -E "s|^VERSION_MINOR=.*|VERSION_MINOR=\"$NEW_MINOR\"|" "$META_FILE"
sed -i.bak -E "s|^VERSION_SUFFIX=.*|VERSION_SUFFIX=\"$NEW_SUFFIX\"|" "$META_FILE"
rm "$META_FILE.bak"
NEW_META=$(grep '^VERSION_MAJOR=' "$META_FILE" | cut -d'"' -f2).$(grep '^VERSION_MINOR=' "$META_FILE" | cut -d'"' -f2).$(grep '^VERSION_SUFFIX=' "$META_FILE" | cut -d'"' -f2)
[[ "$NEW_META" == "$OS_VERSION" ]] || { echo "  FAIL: meta edit didn't take ($NEW_META)"; exit 1; }
echo "  → $NEW_META ✓"
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
if [[ -n "$GA_RELEASE" ]]; then
    HAOS_COMMIT_SUBJECT="release: $GA_RELEASE (ihost $OS_VERSION + supervisor $SUP_VERSION)"
else
    HAOS_COMMIT_SUBJECT="release: ihost $OS_VERSION + supervisor $SUP_VERSION"
fi
commit_repo "$HAOS_VERSION_REPO" "stable.json" \
    "$HAOS_COMMIT_SUBJECT" "$HAOS_VERSION_BRANCH"
commit_repo "$HA_OS_REPO" "buildroot-external/meta" \
    "chore: bump OS version to $OS_VERSION (buildroot-external/meta)" "master"

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
