#!/usr/bin/env bash
# =============================================================================
# selftest.sh — the lockstep gate must distinguish DRIFT from a canary store.
# =============================================================================
# WHY THIS EXISTS
# ---------------
# `check-images.sh` compared the bake pin to the store as a plain string, so any
# store version that was not byte-identical to the pin was a FAIL. That is right
# for drift and wrong for a canary: on 2026-08-19 `ga_hmvapp_addon` sat in the
# store at `1.3.0-ga.1` while the release line was 1.2.x, and adding that add-on
# to the bake would have forced one of two bad outcomes —
#
#   * pin the canary  -> a canary baked into every device, and
#   * pin the release -> this REQUIRED check red on every pull request until a
#                        release happens, which is a deadlock this repo already
#                        paid for once (2026-07-30, the lint path filter).
#
# So a canary store with a release pin is now its own outcome: loud, counted, and
# not fatal. This suite proves the three verdicts stay apart, because the whole
# value of the change is that they do.
#
# The gate runs fully offline here: stable.json is a local file, REPO_ROOT points
# at a scratch tree, and VIBE_ADDONS_REPO_URL clones a git repo we build on the
# spot. No registry, no network, no credentials — so the *lockstep* verdict is
# what is under test and nothing else can colour it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
GATE="$ROOT/scripts/check-images.sh"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; NC=$'\033[0m'
fails=0; ran=0

bad() { printf '  %sFAIL%s  %s\n' "$RED" "$NC" "$*"; fails=$((fails + 1)); }
ok()  { printf '  %sok%s    %s\n' "$GRN" "$NC" "$*"; }

[[ -x "$GATE" ]] || { echo "FATAL: $GATE missing or not executable"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git required"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# stable.json needs the image TEMPLATES present — the gate runs
# `jq '.images.supervisor | sub("{arch}"; …)'` on them and an absent key aborts
# the whole script with "null cannot be matched". They deliberately point at a
# name that does not exist: this suite is about the LOCKSTEP verdict, so the
# system-image lookups are expected to fail offline and every assertion below is
# scoped to the ga_hmvapp_addon lines and the pre-release counter. (First attempt
# used `images: {}` and the gate died before reaching the lockstep section at all
# — all eight cases failed for the same unrelated reason, which is what pointed
# at it.)
cat > "$WORK/stable.json" <<'JSON'
{"supervisor":"0","core":"0","cli":"0","dns":"0","audio":"0","multicast":"0",
 "observer":"0",
 "images":{"supervisor":"localhost:1/none-{arch}","core":"localhost:1/none-{arch}-{machine}",
           "cli":"localhost:1/none-{arch}","dns":"localhost:1/none-{arch}",
           "audio":"localhost:1/none-{arch}","multicast":"localhost:1/none-{arch}",
           "observer":"localhost:1/none-{arch}"}}
JSON

# A scratch REPO_ROOT carrying just the pin file the case wants.
make_pin() { # make_pin <version>
    mkdir -p "$WORK/repo/buildroot-external/package/hassio"
    cat > "$WORK/repo/buildroot-external/package/hassio/addon-images.json" <<JSON
{
  "addons": {
    "ga_hmvapp_addon": {
      "image": "ghcr.io/greenautarky/ga_hmvapp_addon-{arch}",
      "version": "$1"
    }
  }
}
JSON
}

# A throwaway store repo — the gate clones it, so it has to be a real one.
make_store() { # make_store <version>
    rm -rf "$WORK/store"
    mkdir -p "$WORK/store/ga_hmvapp_addon"
    cat > "$WORK/store/ga_hmvapp_addon/config.yaml" <<YAML
name: "GA HMVapp Addon"
version: "$1"
slug: "ga_hmvapp_addon"
image: ghcr.io/greenautarky/ga_hmvapp_addon-{arch}
YAML
    git -C "$WORK/store" init -q -b main
    git -C "$WORK/store" -c user.email=t@e -c user.name=t add -A
    git -C "$WORK/store" -c user.email=t@e -c user.name=t commit -qm store
}

run_case() { # run_case <label> <pin> <store> <expect-regex> <forbid-regex>
    local label="$1" pin="$2" store="$3" expect="$4" forbid="$5" out
    make_pin "$pin"; make_store "$store"
    ran=$((ran + 1))
    out="$(REPO_ROOT="$WORK/repo" VIBE_ADDONS_REPO_URL="$WORK/store" \
           VIBE_ADDONS_REPO_REF=main "$GATE" "$WORK/stable.json" 2>&1)"
    if ! grep -qE "$expect" <<<"$out"; then
        bad "$label — expected /$expect/ in the output"
        sed 's/^/          /' <<<"$out" | grep -iE "hmvapp|Summary|Pre-release|Failed" | head -6
        return
    fi
    if [[ -n "$forbid" ]] && grep -qE "$forbid" <<<"$out"; then
        bad "$label — output must NOT contain /$forbid/"
        sed 's/^/          /' <<<"$out" | grep -iE "hmvapp|Summary|Pre-release|Failed" | head -6
        return
    fi
    ok "$label"
}

echo "== the three verdicts must stay apart =="

# 1. In lockstep. The baseline: without it, a gate that never says OK could pass
#    the other two cases by accident.
run_case "release pin == release store -> OK" \
    "1.2.0" "1.2.0" 'OK.*ga_hmvapp_addon.*lockstep' 'FAIL.*ga_hmvapp_addon'

# 2. Real drift. This must STILL fail — the change must not buy canary tolerance
#    by going soft on the thing the gate exists for. mosquitto drifted for a day
#    on 2026-08-18 and this is the verdict that catches it.
run_case "release pin != release store -> FAIL (drift is still drift)" \
    "1.2.0" "1.3.0" 'FAIL.*ga_hmvapp_addon version mismatch' ''

# 3. The case this change is for.
run_case "release pin, CANARY store -> PRERELEASE, not FAIL" \
    "1.2.0" "1.3.0-ga.1" 'PRERELEASE.*ga_hmvapp_addon' 'FAIL.*ga_hmvapp_addon'

# 4. Deliberately pinning the canary is still lockstep — an operator who decides
#    to bake a canary must not be told it is drift.
run_case "canary pin == canary store -> OK" \
    "1.3.0-ga.1" "1.3.0-ga.1" 'OK.*ga_hmvapp_addon.*lockstep' 'FAIL.*ga_hmvapp_addon'

# 5. A canary pin against a RELEASE store is drift in the dangerous direction:
#    the device would get a canary the store has already moved past. Must fail.
run_case "canary pin, release store -> FAIL (pin behind on a canary)" \
    "1.3.0-ga.1" "1.3.0" 'FAIL.*ga_hmvapp_addon version mismatch' ''

# 6. z2m's `2.12.1-3` is a release REVISION, not a canary. If the predicate
#    treated a bare dash as a canary, real drift on a revisioned add-on would be
#    reported as PRERELEASE and tolerated forever — z2m would silently stop being
#    pinned.
#
#    The pin here has NO suffix, and that is the whole point. The first version of
#    this case used pin `2.12.1-3` against store `2.12.1-4`, and it could not fail:
#    a naive predicate calls BOTH a canary, the branch requires "store canary AND
#    pin release", so it fell through to FAIL and the case passed either way.
#    Decoration. Found by injecting the naive predicate and watching 8/8 stay
#    green — the injection is what exposed the test, not the reverse.
run_case "numeric suffix is a revision, not a canary -> FAIL on drift" \
    "2.12.1" "2.12.1-4" 'FAIL.*ga_hmvapp_addon version mismatch' 'PRERELEASE'

echo "== the outcome has to be visible =="
make_pin "1.2.0"; make_store "1.3.0-ga.1"
out="$(REPO_ROOT="$WORK/repo" VIBE_ADDONS_REPO_URL="$WORK/store" \
       VIBE_ADDONS_REPO_REF=main "$GATE" "$WORK/stable.json" 2>&1)"
ran=$((ran + 1))
if grep -qE '^Pre-release: +1' <<<"$out"; then
    ok "summary counts it (an outcome nobody sees is not an outcome)"
else
    bad "summary does not count the pre-release"
    grep -A5 '=== Summary ===' <<<"$out" | sed 's/^/          /'
fi

# The add-on itself must not be counted as a failure. Scoped to its line rather
# than to the global Failed counter: the system-image lookups above point at a
# nonexistent registry on purpose, so the global count is not 0 here and asserting
# on it would be asserting on the wrong thing.
ran=$((ran + 1))
if ! grep -qE 'FAIL.*ga_hmvapp_addon' <<<"$out"; then
    ok "the canary store produces no FAIL line for the add-on"
else
    bad "a canary store produced a FAIL line for the add-on"
    grep -iE 'hmvapp' <<<"$out" | sed 's/^/          /'
fi

echo
if (( ran == 0 )); then echo "${RED}FATAL${NC} nothing evaluated"; exit 1; fi
if (( fails == 0 )); then
    printf '%slockstep pre-release selftest: %d/%d%s\n' "$GRN" "$ran" "$ran" "$NC"; exit 0
fi
printf '%slockstep pre-release selftest: %d of %d FAILED%s\n' "$RED" "$fails" "$ran" "$NC"; exit 1
