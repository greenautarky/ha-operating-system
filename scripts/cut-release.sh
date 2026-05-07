#!/usr/bin/env bash
# Cut a new GAOS release: bump versions across the three layers AND produce
# the canonical release manifest in greenautarky/releases.
#
# This is Phase 1 of the Fleet Manager rollout (see ga-ihost-docs/TODO.md).
# Use this instead of bump-release-version.sh once the greenautarky/releases
# repo is bootstrapped — it does the same version edits PLUS:
#
#   - Computes git SHAs of all source repos at HEAD → manifest source_pins
#   - Renders releases/v<N>/manifest.yaml from the template (with versions,
#     SHAs, and placeholders for fields that need human review: artifacts'
#     digests/sha256, gates, rollout cohorts, released_at)
#   - Optionally creates and pushes per-repo `v<N>` git tags
#
# Does NOT push anything by default. With --commit it commits per-repo
# (still no push). With --tag it additionally creates an annotated tag.
# Push is always your job.
#
# Usage:
#   ./scripts/cut-release.sh \
#       --os 16.3.1.2 \
#       --supervisor 2025.11.4.3 \
#       --core 2025.11.3.2 \
#       --bundle v1.2 \
#       --branch release/v1.2-rebuild \
#       [--commit] [--tag]
#
# Sibling repos (override via env):
#   HA_CORE_DIR=$HOME/git/homeassisant_core
#   HAOS_VERSION_DIR=$HOME/git/haos-version
#   HA_FRONTEND_DIR=$HOME/git/homeassistant_frontend
#   HA_SUPERVISOR_DIR=$HOME/git/ha-supervisor
#   GA_FLASHER_DIR=$HOME/git/ga-flasher-py
#   GA_DOCS_DIR=$HOME/git/ga-ihost-docs
#   RELEASES_DIR=$HOME/git/releases       (the new private repo)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

HA_CORE_DIR="${HA_CORE_DIR:-${HOME}/git/homeassisant_core}"
HAOS_VERSION_DIR="${HAOS_VERSION_DIR:-${HOME}/git/haos-version}"
HA_FRONTEND_DIR="${HA_FRONTEND_DIR:-${HOME}/git/homeassistant_frontend}"
HA_SUPERVISOR_DIR="${HA_SUPERVISOR_DIR:-${HOME}/git/ha-supervisor}"
GA_FLASHER_DIR="${GA_FLASHER_DIR:-${HOME}/git/ga-flasher-py}"
GA_DOCS_DIR="${GA_DOCS_DIR:-${HOME}/git/ga-ihost-docs}"
RELEASES_DIR="${RELEASES_DIR:-${HOME}/git/releases}"

# --- args -------------------------------------------------------------------
OS_VERSION=""
SUPERVISOR_VERSION=""
CORE_VERSION=""
BUNDLE=""
HAOS_BRANCH=""
DO_COMMIT=0
DO_TAG=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --os)         OS_VERSION="$2"; shift 2 ;;
        --supervisor) SUPERVISOR_VERSION="$2"; shift 2 ;;
        --core)       CORE_VERSION="$2"; shift 2 ;;
        --bundle)     BUNDLE="$2"; shift 2 ;;
        --branch)     HAOS_BRANCH="$2"; shift 2 ;;
        --commit)     DO_COMMIT=1; shift ;;
        --tag)        DO_TAG=1; shift ;;
        --dry-run)    DRY_RUN=1; shift ;;
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

if [[ $DRY_RUN -eq 1 && ($DO_COMMIT -eq 1 || $DO_TAG -eq 1) ]]; then
    echo "ERROR: --dry-run is mutually exclusive with --commit and --tag" >&2
    exit 2
fi

if [[ -z "$OS_VERSION" || -z "$SUPERVISOR_VERSION" || -z "$CORE_VERSION" || -z "$BUNDLE" || -z "$HAOS_BRANCH" ]]; then
    cat >&2 <<USAGE
ERROR: --os, --supervisor, --core, --bundle, and --branch are all required.

Example:
  $0 --bundle v1.2 \\
     --os 16.3.1.2 \\
     --supervisor 2025.11.4.3 \\
     --core 2025.11.3.2 \\
     --branch release/v1.2-rebuild
USAGE
    exit 2
fi

if [[ ! "$BUNDLE" =~ ^v[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: --bundle must match v<MAJOR>.<MINOR>, got '$BUNDLE'" >&2
    exit 2
fi

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

banner() {
    echo
    echo "${BLUE}=== $1 ===${NC}"
}

# --- preflight --------------------------------------------------------------
err=0
[[ -d "$HA_CORE_DIR/.github" ]]      || { echo "${RED}MISSING:${NC} HA_CORE_DIR=$HA_CORE_DIR"; err=1; }
[[ -d "$HAOS_VERSION_DIR/.git" ]]    || { echo "${RED}MISSING:${NC} HAOS_VERSION_DIR=$HAOS_VERSION_DIR"; err=1; }
[[ -d "$RELEASES_DIR/.git" ]]        || { echo "${RED}MISSING:${NC} RELEASES_DIR=$RELEASES_DIR (run \`gh repo create greenautarky/releases --private\` then \`git clone\`)"; err=1; }
[[ -f "${REPO_ROOT}/buildroot-external/meta" ]] || { echo "${RED}MISSING:${NC} buildroot-external/meta"; err=1; }
[[ $err = 0 ]] || exit 3

# --- 1. Run the version-bump (delegates to bump-release-version.sh) --------

banner "Step 1 — bump versions across 3 repos"

BUMP_ARGS=(
    --os "$OS_VERSION"
    --supervisor "$SUPERVISOR_VERSION"
    --core "$CORE_VERSION"
    --branch "$HAOS_BRANCH"
)
[[ $DO_COMMIT = 1 ]] && BUMP_ARGS+=(--commit)
[[ $DRY_RUN = 1 ]]   && BUMP_ARGS+=(--dry-run)

"${SCRIPT_DIR}/bump-release-version.sh" "${BUMP_ARGS[@]}"

# --- 2. Compute source pins (git SHAs of all repos) ------------------------

banner "Step 2 — compute source pins (HEAD SHAs)"

git_sha() {
    local d="$1"
    if [[ -d "$d/.git" ]]; then
        git -C "$d" rev-parse HEAD 2>/dev/null || echo "<unknown>"
    else
        echo "<missing>"
    fi
}

SHA_HAOS=$(git_sha "$REPO_ROOT")
SHA_CORE=$(git_sha "$HA_CORE_DIR")
SHA_FRONTEND=$(git_sha "$HA_FRONTEND_DIR")
SHA_SUPERVISOR=$(git_sha "$HA_SUPERVISOR_DIR")
SHA_HAOS_VERSION=$(git_sha "$HAOS_VERSION_DIR")
SHA_FLASHER=$(git_sha "$GA_FLASHER_DIR")
SHA_DOCS=$(git_sha "$GA_DOCS_DIR")

cat <<PINS
  ha-operating-system    : $SHA_HAOS
  ha-core                : $SHA_CORE
  homeassistant_frontend : $SHA_FRONTEND
  ha-supervisor          : $SHA_SUPERVISOR
  haos-version           : $SHA_HAOS_VERSION
  ga-flasher-py          : $SHA_FLASHER
  ga-ihost-docs          : $SHA_DOCS
PINS

# --- 3. Render releases/<bundle>/manifest.yaml ------------------------------

banner "Step 3 — render releases/${BUNDLE}/manifest.yaml in ${RELEASES_DIR}"

REL_OUT_DIR="${RELEASES_DIR}/releases/${BUNDLE}"

if [[ $DRY_RUN -eq 1 ]]; then
    echo "  ${YELLOW}DRY-RUN${NC}: would write ${REL_OUT_DIR}/manifest.yaml"
    echo "             (with bundle=${BUNDLE}, OS=${OS_VERSION}, Sup=${SUPERVISOR_VERSION}, Core=${CORE_VERSION}, source_pins=current HEADs)"
else

mkdir -p "$REL_OUT_DIR"

cat > "${REL_OUT_DIR}/manifest.yaml" <<EOF
\$schema: "../../schemas/manifest.schema.json"

bundle: "${BUNDLE}"
released_at: "TBD"                                # fill in at Stage 4 promote
released_by: "TBD"                                # fill in at Stage 4 promote
status: "in-development"                          # update to released after Stage 4

versions:
  os: "${OS_VERSION}"
  supervisor: "${SUPERVISOR_VERSION}"
  core: "${CORE_VERSION}"
  frontend_pyversion: "TBD"                       # fill from build-ga-core.yml job output

source_pins:
  ha-operating-system: "${SHA_HAOS}"
  ha-core: "${SHA_CORE}"
  homeassistant_frontend: "${SHA_FRONTEND}"
  ha-supervisor: "${SHA_SUPERVISOR}"
  haos-version: "${SHA_HAOS_VERSION}"
  ga-flasher-py: "${SHA_FLASHER}"
  ga-ihost-docs: "${SHA_DOCS}"

artifacts:
  raucb:
    url: "https://ota.greenautarky.com/releases/${OS_VERSION}/haos_ihost-${OS_VERSION}.raucb"
    sha256: "TBD"                                 # sha256sum of the .raucb after build
    size_bytes: 0                                 # \`stat --format=%s ...\`
  containers:
    core:
      tag: "ghcr.io/greenautarky/tinker-homeassistant:${CORE_VERSION}"
      digest: "sha256:TBD"                        # \`docker manifest inspect <tag>\` after promote
    supervisor:
      tag: "ghcr.io/greenautarky/armv7-hassio-supervisor:${SUPERVISOR_VERSION}"
      digest: "sha256:TBD"

gates:
  build_tests: "n/a"
  device_tests: "n/a"
  e2e_tests: "n/a"
  ota_test: "n/a"
  cve_scan:
    critical: 0
    high: 0
    medium: 0
  signed_off_by: []

rollout:
  cohorts:
    canary:
      devices: ["KIB-SON-00000000"]
      schedule: "manual"
      gate: "manual"
    pilot:
      devices: []                                 # populate at Stage 3
      schedule: "manual"
      gate: "canary-clean-7d"
    fleet:
      devices: "all-except-pilot"
      schedule: "manual"
      gate: "pilot-clean-7d"
  windows:
    fleet:
      weekdays: ["tue", "wed", "thu"]
      hours: ["02:00", "04:00"]
  retry:
    max_attempts: 3
    backoff_minutes: [5, 30, 240]

notes: |
  Initial manifest cut at $(date -u +%Y-%m-%dT%H:%M:%SZ) by cut-release.sh.
  TBD fields require manual completion before Stage 4 sign-off.
EOF

echo "  wrote ${REL_OUT_DIR}/manifest.yaml"
echo
echo "${YELLOW}Manual completion required (TBD fields):${NC}"
echo "  - frontend_pyversion (after ha-core CI run)"
echo "  - artifacts.raucb.sha256 / size_bytes (after OS prod build)"
echo "  - artifacts.containers.*.digest (after Stage 4 promote)"
echo "  - released_at / released_by (at Stage 4 promote)"
echo "  - gates (per-test results + sign-off entries)"
echo "  - rollout.cohorts.pilot.devices (at Stage 3)"

fi  # end of: if [[ $DRY_RUN -eq 1 ]] / else

# --- 4. Run validator on the new manifest ----------------------------------

if [[ $DRY_RUN -eq 0 ]]; then
banner "Step 4 — validate manifest"

if [[ -x "${RELEASES_DIR}/tools/validate.py" ]]; then
    cd "$RELEASES_DIR"
    python3 tools/validate.py "releases/${BUNDLE}/" || {
        echo "${YELLOW}Validation failed (expected — TBD fields don't satisfy schema yet).${NC}"
        echo "${YELLOW}Fix the TBD fields and re-run \`python3 tools/validate.py releases/${BUNDLE}/\`${NC}"
    }
    cd - >/dev/null
else
    echo "${YELLOW}validate.py not found at ${RELEASES_DIR}/tools/validate.py — skipping validation${NC}"
fi

fi  # end of: if [[ $DRY_RUN -eq 0 ]] (Step 4)

# --- 5. Optionally create release tag in each repo --------------------------

if [[ $DO_TAG = 1 ]]; then
    banner "Step 5 — create signed tag ${BUNDLE} in each source repo"

    tag_repo() {
        local d="$1" name="$2"
        if [[ ! -d "$d/.git" ]]; then
            echo "  ${YELLOW}skip${NC} $name (not a git repo): $d"
            return
        fi
        if git -C "$d" rev-parse "$BUNDLE" >/dev/null 2>&1; then
            echo "  ${YELLOW}exists${NC} $name: $BUNDLE already tagged"
            return
        fi
        if git -C "$d" tag -s "$BUNDLE" -m "GAOS bundle ${BUNDLE} (OS ${OS_VERSION}, supervisor ${SUPERVISOR_VERSION}, core ${CORE_VERSION})" 2>&1 \
            | head -3 | sed 's/^/    /'; then
            echo "  ${GREEN}✓${NC} $name: tagged $BUNDLE"
        else
            # Try unsigned as fallback
            git -C "$d" tag -a "$BUNDLE" -m "GAOS bundle ${BUNDLE} (OS ${OS_VERSION}, supervisor ${SUPERVISOR_VERSION}, core ${CORE_VERSION})"
            echo "  ${GREEN}✓${NC} $name: tagged $BUNDLE (unsigned — gpg key missing?)"
        fi
    }

    tag_repo "$REPO_ROOT"          "ha-operating-system"
    tag_repo "$HA_CORE_DIR"        "ha-core"
    tag_repo "$HA_FRONTEND_DIR"    "homeassistant_frontend"
    tag_repo "$HA_SUPERVISOR_DIR"  "ha-supervisor"
    tag_repo "$HAOS_VERSION_DIR"   "haos-version"
    tag_repo "$GA_FLASHER_DIR"     "ga-flasher-py"
    tag_repo "$GA_DOCS_DIR"        "ga-ihost-docs"
    tag_repo "$RELEASES_DIR"       "releases"

    cat <<PUSH_HINT

Push tags manually after review:
  for d in $REPO_ROOT $HA_CORE_DIR $HA_FRONTEND_DIR $HA_SUPERVISOR_DIR $HAOS_VERSION_DIR $GA_FLASHER_DIR $GA_DOCS_DIR $RELEASES_DIR; do
      ( cd "\$d" && git push origin "${BUNDLE}" 2>&1 | sed "s/^/[\$(basename \$d)] /" )
  done

PUSH_HINT
fi

# --- 6. Summary -------------------------------------------------------------

banner "DONE"

if [[ $DRY_RUN -eq 1 ]]; then
cat <<DONE
${YELLOW}DRY-RUN — nothing changed.${NC}

Would have:
  Bundle:    ${BUNDLE}
  OS:        ${OS_VERSION}
  Sup:       ${SUPERVISOR_VERSION}
  Core:      ${CORE_VERSION}
  Manifest:  ${REL_OUT_DIR}/manifest.yaml (would be written, not yet)

Re-run without --dry-run (or with --commit) to apply.
DONE
else
cat <<DONE
Bundle:    ${BUNDLE}
OS:        ${OS_VERSION}
Sup:       ${SUPERVISOR_VERSION}
Core:      ${CORE_VERSION}
Manifest:  ${REL_OUT_DIR}/manifest.yaml

${YELLOW}Push checklist (manual):${NC}
  cd ${HA_CORE_DIR}      && git push                                    # → triggers CI build of :ci-{sha}
  cd ${HAOS_VERSION_DIR} && git push -u origin ${HAOS_BRANCH}
  cd ${REPO_ROOT}        && git push
  cd ${RELEASES_DIR}     && git add releases/${BUNDLE}/ && git commit && git push

After CI builds the staging tag, promote with:
  gh workflow run "Build greenautarky HA Core image" \\
      --repo greenautarky/ha-core \\
      --ref ga/custom-onboarding \\
      -f tag=${CORE_VERSION}

Update manifest TBD fields (frontend_pyversion, digests, gates), then validate:
  cd ${RELEASES_DIR} && python3 tools/validate.py releases/${BUNDLE}/

Stage 4 fleet promote when ready: merge ${HAOS_BRANCH} → main on haos-version.
DONE
fi
