#!/usr/bin/env bash
# Bump the three layers of a GAOS release in one transaction across sibling repos.
#
# What it edits (3 places, 3 repos):
#   1. ha-operating-system  → buildroot-external/meta            : VERSION_SUFFIX
#   2. ha-core              → .github/workflows/build-ga-core.yml: HA_VERSION env (+ default)
#   3. haos-version         → stable.json on a release branch    : hassos.ihost
#                                                                : supervisor
#                                                                : homeassistant.<all-boards>
#
# This script does NOT assume lock-step .N counters across layers — you
# supply each version string explicitly, because the supervisor counter
# may diverge from OS/Core (legacy from the rolling-Core era).
#
# Does NOT push anything. Edits local checkouts, prints diffs, and
# commits per-repo only with --commit. Push is your job.
#
# Usage:
#   ./scripts/bump-release-version.sh \
#     --os 16.3.1.2 \
#     --supervisor 2025.11.4.3 \
#     --core 2025.11.3.2 \
#     --branch release/v1.2-rebuild \
#     [--commit]
#
# Sibling repos (override via env if checked out elsewhere):
#   HA_CORE_DIR=$HOME/git/homeassisant_core      (note typo from upstream)
#   HAOS_VERSION_DIR=$HOME/git/haos-version
#
# See: ga-ihost-docs/RELEASING.md → Versioning strategy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

HA_CORE_DIR="${HA_CORE_DIR:-${HOME}/git/homeassisant_core}"
HAOS_VERSION_DIR="${HAOS_VERSION_DIR:-${HOME}/git/haos-version}"

# --- args -------------------------------------------------------------------
OS_VERSION=""
SUPERVISOR_VERSION=""
CORE_VERSION=""
HAOS_BRANCH=""
DO_COMMIT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --os)         OS_VERSION="$2"; shift 2 ;;
        --supervisor) SUPERVISOR_VERSION="$2"; shift 2 ;;
        --core)       CORE_VERSION="$2"; shift 2 ;;
        --branch)     HAOS_BRANCH="$2"; shift 2 ;;
        --commit)     DO_COMMIT=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown arg: $1" >&2
            exit 2
            ;;
    esac
done

if [[ -z "$OS_VERSION" || -z "$SUPERVISOR_VERSION" || -z "$CORE_VERSION" || -z "$HAOS_BRANCH" ]]; then
    cat >&2 <<USAGE
ERROR: --os, --supervisor, --core, and --branch are all required.

Example:
  $0 --os 16.3.1.2 --supervisor 2025.11.4.3 --core 2025.11.3.2 --branch release/v1.2-rebuild
USAGE
    exit 2
fi

# Sanity check: no trailing .0 (AwesomeVersion strips them, breaks comparisons)
for v in "$OS_VERSION" "$SUPERVISOR_VERSION" "$CORE_VERSION"; do
    if [[ "$v" =~ \.0$ ]]; then
        echo "ERROR: version '$v' has trailing .0 — AwesomeVersion strips it, breaking comparisons" >&2
        exit 2
    fi
done

# --- colours ----------------------------------------------------------------
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

banner() {
    echo
    echo "${BLUE}=== $1 ===${NC}"
}

# OS suffix derivation: strip "16.3." prefix (or whatever leading "X.Y.")
# Buildroot's name.sh reads VERSION_SUFFIX as the trailing part after the
# upstream HAOS major (16.3). For 16.3.1.2 → suffix is "1.2".
OS_SUFFIX="${OS_VERSION#*.*.}"   # 16.3.1.2 → 1.2

cat <<INFO
${GREEN}Per-release version bump${NC}
  OS         → ${OS_VERSION}      → VERSION_SUFFIX="${OS_SUFFIX}"
  Supervisor → ${SUPERVISOR_VERSION}
  Core       → ${CORE_VERSION}

stable.json branch on haos-version: ${HAOS_BRANCH}
Sibling repos:
  ha-core      = ${HA_CORE_DIR}
  haos-version = ${HAOS_VERSION_DIR}

Commit per-repo:    $([ $DO_COMMIT = 1 ] && echo "yes" || echo "${YELLOW}no${NC} (use --commit to commit)")
Push:                ${RED}NEVER${NC} (push is your job — review the diffs)

INFO

# --- preflight --------------------------------------------------------------
err=0
[[ -d "$HA_CORE_DIR/.github" ]]      || { echo "${RED}MISSING:${NC} HA_CORE_DIR=$HA_CORE_DIR (override with env)";      err=1; }
[[ -d "$HAOS_VERSION_DIR/.git" ]]    || { echo "${RED}MISSING:${NC} HAOS_VERSION_DIR=$HAOS_VERSION_DIR (override with env)"; err=1; }
[[ -f "${REPO_ROOT}/buildroot-external/meta" ]] || { echo "${RED}MISSING:${NC} ${REPO_ROOT}/buildroot-external/meta"; err=1; }
[[ $err = 0 ]] || exit 3

# --- 1. ha-operating-system: VERSION_SUFFIX --------------------------------
banner "1. ha-operating-system → buildroot-external/meta"

META="${REPO_ROOT}/buildroot-external/meta"
CURRENT_OS_SUFFIX=$(grep -oE 'VERSION_SUFFIX="[^"]*"' "$META" | cut -d'"' -f2 || true)

if [[ "$CURRENT_OS_SUFFIX" = "$OS_SUFFIX" ]]; then
    echo "  already at VERSION_SUFFIX=\"$OS_SUFFIX\" — nothing to do"
else
    echo "  VERSION_SUFFIX: \"${CURRENT_OS_SUFFIX}\" → \"${OS_SUFFIX}\""
    sed -i "s/VERSION_SUFFIX=\"${CURRENT_OS_SUFFIX}\"/VERSION_SUFFIX=\"${OS_SUFFIX}\"/" "$META"
    git -C "$REPO_ROOT" --no-pager diff -- buildroot-external/meta | sed 's/^/    /'
fi

# --- 2. ha-core: HA_VERSION env in build-ga-core.yml ------------------------
banner "2. ha-core → .github/workflows/build-ga-core.yml"

CORE_WF="${HA_CORE_DIR}/.github/workflows/build-ga-core.yml"
if [[ ! -f "$CORE_WF" ]]; then
    echo "${RED}ERROR:${NC} workflow file not found: $CORE_WF"
    exit 4
fi

CURRENT_HA_VER=$(grep -E '^[[:space:]]*HA_VERSION:' "$CORE_WF" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
if [[ -z "$CURRENT_HA_VER" ]]; then
    echo "${RED}ERROR:${NC} could not parse HA_VERSION env from $CORE_WF"
    exit 4
fi
if [[ "$CURRENT_HA_VER" = "$CORE_VERSION" ]]; then
    echo "  already at HA_VERSION: ${CORE_VERSION} — nothing to do"
else
    echo "  HA_VERSION: ${CURRENT_HA_VER} → ${CORE_VERSION}"
    # Quoted or unquoted env: line (preserve quoting)
    sed -i -E "s/(HA_VERSION:[[:space:]]*\"?)${CURRENT_HA_VER//./\\.}(\"?)/\1${CORE_VERSION}\2/" "$CORE_WF"
    # workflow_dispatch input default: line, if it matches the old version
    sed -i -E "s/^([[:space:]]+default:[[:space:]]*['\"]?)${CURRENT_HA_VER//./\\.}(['\"]?)/\1${CORE_VERSION}\2/" "$CORE_WF"
    git -C "$HA_CORE_DIR" --no-pager diff -- .github/workflows/build-ga-core.yml | sed 's/^/    /'
fi

# --- 3. haos-version: stable.json on the release branch ---------------------
banner "3. haos-version → stable.json on ${HAOS_BRANCH}"

git -C "$HAOS_VERSION_DIR" fetch origin --quiet || true
if git -C "$HAOS_VERSION_DIR" rev-parse --verify "$HAOS_BRANCH" >/dev/null 2>&1; then
    git -C "$HAOS_VERSION_DIR" checkout "$HAOS_BRANCH"
elif git -C "$HAOS_VERSION_DIR" rev-parse --verify "origin/$HAOS_BRANCH" >/dev/null 2>&1; then
    git -C "$HAOS_VERSION_DIR" checkout -b "$HAOS_BRANCH" "origin/$HAOS_BRANCH"
else
    echo "  ${YELLOW}branch '${HAOS_BRANCH}' does not exist locally or on origin${NC}"
    echo "  creating from current main..."
    git -C "$HAOS_VERSION_DIR" checkout main
    git -C "$HAOS_VERSION_DIR" pull --ff-only --quiet || true
    git -C "$HAOS_VERSION_DIR" checkout -b "$HAOS_BRANCH"
fi

STABLE_JSON="${HAOS_VERSION_DIR}/stable.json"
[[ -f "$STABLE_JSON" ]] || { echo "${RED}ERROR:${NC} stable.json not found at $STABLE_JSON"; exit 5; }

python3 - "$STABLE_JSON" "$SUPERVISOR_VERSION" "$CORE_VERSION" "$OS_VERSION" <<'PY'
import json, sys, pathlib
path, sup_v, core_v, os_v = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
p = pathlib.Path(path)
d = json.loads(p.read_text())
d["supervisor"] = sup_v
ha = d.get("homeassistant", {})
for k in ha:
    ha[k] = core_v
d["homeassistant"] = ha
hassos = d.get("hassos", {})
hassos["ihost"] = os_v
d["hassos"] = hassos
# stable.json on this repo uses 2-space indent
p.write_text(json.dumps(d, indent=2) + "\n")
PY

git -C "$HAOS_VERSION_DIR" --no-pager diff -- stable.json | sed 's/^/    /' | head -60

# --- commit if asked --------------------------------------------------------
if [[ $DO_COMMIT = 1 ]]; then
    banner "Committing per repo (NOT pushing)"

    if ! git -C "$REPO_ROOT" diff --quiet -- buildroot-external/meta; then
        git -C "$REPO_ROOT" add buildroot-external/meta
        git -C "$REPO_ROOT" commit -m "release: bump OS version to ${OS_VERSION}"
        echo "  ${GREEN}✓${NC} committed in ha-operating-system"
    fi

    if ! git -C "$HA_CORE_DIR" diff --quiet -- .github/workflows/build-ga-core.yml; then
        git -C "$HA_CORE_DIR" add .github/workflows/build-ga-core.yml
        git -C "$HA_CORE_DIR" commit -m "release: bump HA_VERSION to ${CORE_VERSION}"
        echo "  ${GREEN}✓${NC} committed in ha-core"
    fi

    if ! git -C "$HAOS_VERSION_DIR" diff --quiet -- stable.json; then
        git -C "$HAOS_VERSION_DIR" add stable.json
        git -C "$HAOS_VERSION_DIR" commit -m "release: bump bundle on ${HAOS_BRANCH} (OS ${OS_VERSION}, supervisor ${SUPERVISOR_VERSION}, core ${CORE_VERSION})"
        echo "  ${GREEN}✓${NC} committed in haos-version on ${HAOS_BRANCH}"
    fi

    cat <<NEXT

${YELLOW}NOT pushed.${NC} Review the commits, then push manually:

  cd ${HA_CORE_DIR}      && git push                               # → triggers CI build of :ci-{sha}
  cd ${HAOS_VERSION_DIR} && git push -u origin ${HAOS_BRANCH}      # → makes release branch visible
  cd ${REPO_ROOT}        && git push                               # → master

After CI builds the staging tag, promote with:
  gh workflow run "Build greenautarky HA Core image" \\
    --repo greenautarky/ha-core \\
    --ref ga/custom-onboarding \\
    -f tag=${CORE_VERSION}

NEXT
else
    cat <<REVIEW

${YELLOW}Edits applied but not committed.${NC} Use --commit to commit per repo.
Or commit manually after reviewing the diffs above.

REVIEW
fi
