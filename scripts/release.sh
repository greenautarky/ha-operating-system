#!/bin/bash
# release.sh — Bump versions for a new release, commit, and push.
#
# Updates five places that MUST stay in sync:
#   1. ha-supervisor/supervisor/const.py            SUPERVISOR_VERSION
#   2. haos-version/stable.json                      "supervisor" key
#   3. haos-version/stable.json                      "ihost" key (under hassos)
#   4. haos-version/stable.json                      "ga_release" key   (since v1.2)
#   5. ha-operating-system/version.yaml              "gaos_release:" key (since BOSv1.2.4 — read by ga_build.sh)
#   6. ha-operating-system/buildroot-external/meta   VERSION_{MAJOR,MINOR,SUFFIX}
#
# After this runs, the next steps are MANUAL (intentionally):
#   a. SSH ga-builder, run: ./scripts/ga_build.sh update prod
#      (GA_RELEASE env is no longer needed — ga_build.sh reads version.yaml.
#       Or use --bake-async on this script to kick the bake automatically.)
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
BAKE_ASYNC=false
OS_VERSION=""
SUP_VERSION=""
GA_RELEASE=""  # optional; if unset we preserve whatever is in stable.json

# --bake-async support: ga-builder LXC on the Proxmox host runs the actual
# build. Override these if your topology differs.
GA_BUILDER_HOST="${GA_BUILDER_HOST:-root@192.168.1.33}"
GA_BUILDER_CTID="${GA_BUILDER_CTID:-107}"
GA_BUILDER_REPO_PATH="${GA_BUILDER_REPO_PATH:-/home/builder/ha-operating-system}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)     DRY_RUN=true; shift ;;
        --no-push)     NO_PUSH=true; shift ;;
        --bake-async)  BAKE_ASYNC=true; shift ;;
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
# (since 2026-06-02) is BOSvMAJOR.MINOR.PATCH (e.g. BOSv1.2.1). Since
# Option C went live 2026-06-17, optional -rcN / -devN pre-release
# suffixes are also accepted (e.g. BOSv1.2.21-rc2, BOSv1.2.22-dev3).
if [[ -n "$GA_RELEASE" ]] && ! [[ "$GA_RELEASE" =~ ^BOSv[0-9]+\.[0-9]+\.[0-9]+(-(rc|dev)[0-9]+)?$ ]]; then
    echo "ERROR: ga_release '$GA_RELEASE' looks malformed (expected BOSvMAJOR.MINOR.PATCH[-{rc,dev}N])"
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

# version.yaml `gaos_release:` is the build-time source of truth for the
# /etc/ga-release stamp (read by scripts/ga_build.sh — see GA_RELEASE
# resolution there). When --ga-release is given, keep it in sync with
# stable.json so a single `release.sh` invocation covers all knobs.
if [[ -n "$GA_RELEASE" ]]; then
    VERSION_YAML="$HA_OS_REPO/version.yaml"
    if [[ -f "$VERSION_YAML" ]]; then
        echo "Applying version.yaml gaos_release..."
        # Match the canonical "gaos_release: BOSv… # comment" shape — preserve
        # the inline comment if present, replace only the value token.
        sed -i.bak -E "s|^(gaos_release:[[:space:]]*)\"?[^\"#[:space:]]+\"?([[:space:]]*#.*)?\$|\1$GA_RELEASE\2|" "$VERSION_YAML"
        rm "$VERSION_YAML.bak"
        NEW_YAML_REL=$(sed -nE 's/^gaos_release:[[:space:]]*"?([^"#[:space:]]+)"?.*$/\1/p' "$VERSION_YAML" | head -1)
        [[ "$NEW_YAML_REL" == "$GA_RELEASE" ]] || {
            echo "  FAIL: version.yaml edit didn't take ($NEW_YAML_REL)"; exit 1;
        }
        echo "  → $NEW_YAML_REL ✓"
    else
        echo "  (skip) version.yaml not present at $VERSION_YAML"
    fi
fi
echo ""

# Commit + push
#
# $2 (file) may be a single path OR a space-separated list. Word-splitting is
# intentional here so callers can stage e.g. "buildroot-external/meta version.yaml"
# in a single commit. shellcheck-disable=SC2086 lives below for that reason.
commit_repo() {
    local repo="$1" file="$2" subject="$3" branch="$4"
    cd "$repo"
    # shellcheck disable=SC2086 # word-split intentionally; see comment above
    git add $file
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
# Stage version.yaml alongside meta in the ha-operating-system commit when
# we touched it above (i.e. --ga-release was supplied). Single commit, single
# push — the meta + gaos_release pair must always land together.
HA_OS_FILES="buildroot-external/meta"
HA_OS_SUBJECT="chore: bump OS version to $OS_VERSION (buildroot-external/meta)"
if [[ -n "$GA_RELEASE" && -f "$HA_OS_REPO/version.yaml" ]]; then
    HA_OS_FILES="$HA_OS_FILES version.yaml"
    HA_OS_SUBJECT="chore: bump OS to $OS_VERSION + gaos_release=$GA_RELEASE"
fi
commit_repo "$HA_OS_REPO" "$HA_OS_FILES" "$HA_OS_SUBJECT" "master"

echo ""
echo "============================================="
echo "  Versions bumped + pushed ✓"
echo "============================================="
echo ""

# Optional: kick the bake immediately on ga-builder so the operator
# doesn't have to wait + remember to do it manually. The bake runs
# detached (= release.sh returns); operator monitors via
#   ssh root@<ga-builder> 'pct exec <CTID> -- docker logs ga-build'
# Robust against the GA_RELEASE-stripping bug because we just bumped
# version.yaml + pushed; the bake will pick up the right value via
# ga_build.sh's yaml fallback (see fix/ga-build-ga-release-robustness).
if [[ "$BAKE_ASYNC" == "true" ]]; then
    echo "Kicking bake on ga-builder ($GA_BUILDER_HOST CTID=$GA_BUILDER_CTID)..."
    REMOTE_CMD=$(cat <<REMOTE
set -e
cd $GA_BUILDER_REPO_PATH
git pull --ff-only
echo "On commit: \$(git log --oneline -1)"
echo "Version.yaml gaos_release: \$(grep '^gaos_release:' version.yaml | head -1)"
docker rm -f ga-build 2>/dev/null || true
rm -f ga_output/build/hassio-1.0.0/.stamp_target_installed 2>/dev/null || true
rm -f ga_output/build/hassio-1.0.0/.stamp_installed 2>/dev/null || true
docker run -d --privileged \\
    -v \\\$(pwd):/build -v /home/builder/hassos-cache:/cache -v /dev:/dev \\
    -v /home/builder/secrets:/secrets:ro \\
    -v /root/.docker/config.json:/root/.docker/config.json:ro \\
    --name ga-build \\
    hassos:local bash -c "export FORCE_UNSAFE_CONFIGURE=1 && cd /build && ./scripts/ga_build.sh update prod"
echo "Bake kicked. Container: ga-build"
REMOTE
)
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "(DRY-RUN) Would run on $GA_BUILDER_HOST:"
        echo "$REMOTE_CMD" | sed 's/^/  | /'
    else
        ssh -o ConnectTimeout=15 "$GA_BUILDER_HOST" "pct exec $GA_BUILDER_CTID -- bash -c \"$REMOTE_CMD\""
        echo ""
        echo "  Bake running detached. Monitor with:"
        echo "    ssh $GA_BUILDER_HOST 'pct exec $GA_BUILDER_CTID -- docker logs -f ga-build'"
        echo "  Or poll for the final artifact:"
        echo "    ssh $GA_BUILDER_HOST 'pct exec $GA_BUILDER_CTID -- ls -lht $GA_BUILDER_REPO_PATH/ga_output/images/bos_ihost-${OS_VERSION}_prod_*.img.xz'"
    fi
    echo ""
fi

echo "Next steps (manual):"
if [[ "$BAKE_ASYNC" != "true" ]]; then
    echo "  1. Build on ga-builder:"
    echo "       ssh ga-builder 'cd /home/builder/ha-operating-system && git pull && ./scripts/ga_build.sh update prod'"
    echo "     (or re-run with --bake-async to kick it from here)"
fi
echo "  2. Once .img.xz + .raucb are produced, copy to laptop + upload:"
echo "       ./scripts/push-ota.sh --server --raucb /path/to/bos_ihost-${OS_VERSION}_prod_<TS>.raucb"
echo "  3. Canary verify on K0 via fleet-manager ota-update job before fleet cascade"
echo "  4. PUBLISH THE RELEASE EVIDENCE — a promoted version without it is not"
echo "     traceable, and the build-side copy is overwritten by the NEXT build:"
echo "       ssh ga-builder 'ls /build/release-evidence/'   # find the build id"
echo "       # then copy that <build-id>/<version>/ dir into a checkout of"
echo "       # greenautarky/ga-release-evidence (PRIVATE) and commit it."
echo "     Read EVIDENCE.md first: it states its OWN coverage, including whether"
echo "     the CVE enrichment actually ran and whether the tree was dirty."
echo ""
