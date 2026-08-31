#!/usr/bin/env bash
# =============================================================================
# selftest.sh — scripts/repin-addons.py must go BOTH red and green, and it must
#               agree with the gate whose red bake it exists to prevent.
# =============================================================================
# WHY THIS EXISTS
# ---------------
# repin-addons.py rewrites the bake pins to the vibe_addons store and can stamp
# the rc marker. A repin tool that is WRONG is worse than none: it would write a
# pin the enforcing gate (scripts/check-images.sh, the `check-versions` job) then
# rejects, i.e. produce the exact red-bake-discovered-late this whole thing is
# meant to remove. So two things are proven here on every PR, offline:
#
#   1. --check goes red on drift and green on lockstep (a check that only ever
#      passes is not a check), the marker edit is surgical, and the coverage
#      guards fire.
#   2. repin's verdict AGREES with the real check-images.sh over the same
#      fixtures — drift, lockstep, canary, and a pin with no store entry. This is
#      the mechanism that keeps the two store readers from drifting apart, rather
#      than a comment asking them not to. If someone changes one join and not the
#      other, a case below goes red.
#
# Runs fully offline: the store is a git repo built on the spot (check-images.sh
# clones it, repin reads it via --store), REPO_ROOT points at a scratch tree, and
# stable.json is a local file with image templates that deliberately do not
# resolve — so the LOCKSTEP verdict is what is under test and the registry cannot
# colour it. Every gate assertion is scoped to the ga_hmvapp_addon lines and the
# "out of lockstep" counter, never the gate's overall exit code (its system-image
# lookups fail on purpose here).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
REPIN="$ROOT/scripts/repin-addons.py"
GATE="$ROOT/scripts/check-images.sh"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; NC=$'\033[0m'
fails=0; ran=0
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$NC" "$*"; fails=$((fails + 1)); }
ok()  { printf '  %sok%s    %s\n' "$GRN" "$NC" "$*"; }

[[ -f "$REPIN" ]] || { echo "FATAL: $REPIN missing"; exit 1; }
[[ -x "$GATE"  ]] || { echo "FATAL: $GATE missing or not executable"; exit 1; }
command -v git     >/dev/null 2>&1 || { echo "FATAL: git required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

IMAGE="ghcr.io/greenautarky/ga_hmvapp_addon-{arch}"

# stable.json needs the image TEMPLATES present or the gate aborts before the
# lockstep section (jq '… | sub("{arch}";…)' on an absent key dies). They point
# at a name that does not exist on purpose — same trick as the lockstep_prerelease
# selftest — because only the lockstep verdict is under test here.
cat > "$WORK/stable.json" <<'JSON'
{"supervisor":"0","core":"0","cli":"0","dns":"0","audio":"0","multicast":"0",
 "observer":"0",
 "images":{"supervisor":"localhost:1/none-{arch}","core":"localhost:1/none-{arch}-{machine}",
           "cli":"localhost:1/none-{arch}","dns":"localhost:1/none-{arch}",
           "audio":"localhost:1/none-{arch}","multicast":"localhost:1/none-{arch}",
           "observer":"localhost:1/none-{arch}"}}
JSON

# A scratch REPO_ROOT carrying just the two files the tool touches.
make_repo() { # make_repo <pin-version> <pin-image> [marker]
    mkdir -p "$WORK/repo/buildroot-external/package/hassio"
    cat > "$WORK/repo/buildroot-external/package/hassio/addon-images.json" <<JSON
{
  "addons": {
    "ga_hmvapp_addon": {
      "image": "$2",
      "version": "$1"
    }
  }
}
JSON
    if [[ -n "${3:-}" ]]; then
        cat > "$WORK/repo/version.yaml" <<YAML
# scratch version.yaml for the marker selftest
gaos_release: $3  # KEEP-THIS-COMMENT-VERBATIM operator edits this by hand
YAML
    fi
}

# A throwaway store repo — check-images.sh CLONES it, so it must be real.
make_store() { # make_store <version>
    rm -rf "$WORK/store"
    mkdir -p "$WORK/store/ga_hmvapp_addon"
    cat > "$WORK/store/ga_hmvapp_addon/config.yaml" <<YAML
name: "GA HMVapp Addon"
version: "$1"
slug: "ga_hmvapp_addon"
image: $IMAGE
YAML
    git -C "$WORK/store" init -q -b main
    git -C "$WORK/store" -c user.email=t@e -c user.name=t add -A
    git -C "$WORK/store" -c user.email=t@e -c user.name=t commit -qm store
}

# repin --check: capture output AND the real exit code (no pipe — a pipe reports
# the pipe's status, which is how a gate looks green while failing).
repin_check() { # repin_check  -> sets $out, $rc
    out="$(REPO_ROOT="$WORK/repo" python3 "$REPIN" --check --store "$WORK/store" 2>&1)"; rc=$?
}
repin_apply() { # repin_apply  -> sets $out, $rc  (default write mode)
    out="$(REPO_ROOT="$WORK/repo" python3 "$REPIN" --store "$WORK/store" 2>&1)"; rc=$?
}
# The real gate over the same fixtures. Assert on its lockstep LINES, not its exit.
gate_run() { # gate_run -> sets $gout
    gout="$(REPO_ROOT="$WORK/repo" VIBE_ADDONS_REPO_URL="$WORK/store" \
            VIBE_ADDONS_REPO_REF=main "$GATE" "$WORK/stable.json" 2>&1 || true)"
}

pin_version() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["addons"]["ga_hmvapp_addon"]["version"])' \
                "$WORK/repo/buildroot-external/package/hassio/addon-images.json"; }

echo "== 1. lockstep: --check green AND the gate agrees =="
make_repo "1.2.0" "$IMAGE"; make_store "1.2.0"
ran=$((ran + 1)); repin_check
if [[ $rc -eq 0 ]] && grep -qE 'OK: every pin is in lockstep' <<<"$out"; then
    ok "repin --check exits 0 on lockstep"
else bad "repin --check should be green on lockstep (rc=$rc)"; sed 's/^/      /' <<<"$out"; fi
ran=$((ran + 1)); gate_run
if grep -qE 'OK.*ga_hmvapp_addon.*lockstep' <<<"$gout" && grep -qE 'out of lockstep: 0' <<<"$gout"; then
    ok "check-images.sh agrees: OK / out of lockstep: 0"
else bad "gate disagrees on lockstep"; grep -iE 'hmvapp|out of lockstep' <<<"$gout" | sed 's/^/      /'; fi
# and default mode is a no-op that changes nothing
ran=$((ran + 1)); before="$(cat "$WORK/repo/buildroot-external/package/hassio/addon-images.json")"
repin_apply; after="$(cat "$WORK/repo/buildroot-external/package/hassio/addon-images.json")"
if [[ $rc -eq 0 && "$before" == "$after" ]] && grep -qE 'already in lockstep' <<<"$out"; then
    ok "default mode is a byte-for-byte no-op when already in lockstep"
else bad "default mode changed a file that was already in lockstep"; diff <(echo "$before") <(echo "$after") | sed 's/^/      /'; fi

echo "== 2. drift: --check red, gate agrees, then default mode corrects it =="
make_repo "1.2.0" "$IMAGE"; make_store "1.3.0"
ran=$((ran + 1)); repin_check
if [[ $rc -ne 0 ]] && grep -qE 'DRIFT ga_hmvapp_addon: pinned 1.2.0 -> store 1.3.0' <<<"$out"; then
    ok "repin --check exits non-zero and names the drift"
else bad "repin --check should be red and name the drift (rc=$rc)"; sed 's/^/      /' <<<"$out"; fi
ran=$((ran + 1)); gate_run
if grep -qE 'FAIL.*ga_hmvapp_addon version mismatch' <<<"$gout" && grep -qE 'out of lockstep: 1' <<<"$gout"; then
    ok "check-images.sh agrees: FAIL version mismatch / out of lockstep: 1"
else bad "gate disagrees on drift"; grep -iE 'hmvapp|out of lockstep' <<<"$gout" | sed 's/^/      /'; fi
# default mode fixes it, changing ONLY the version string
ran=$((ran + 1)); before="$(cat "$WORK/repo/buildroot-external/package/hassio/addon-images.json")"
repin_apply; after="$(cat "$WORK/repo/buildroot-external/package/hassio/addon-images.json")"
changed="$(diff <(echo "$before") <(echo "$after") | grep -E '^[<>]' || true)"
if [[ $rc -eq 0 && "$(pin_version)" == "1.3.0" ]] \
   && [[ "$(grep -cE '^[<>]' <<<"$changed")" -eq 2 ]] \
   && grep -qE '^< *"version": "1.2.0"' <<<"$changed" \
   && grep -qE '^> *"version": "1.3.0"' <<<"$changed"; then
    ok "default mode repins to 1.3.0 and ONLY the version line changed"
else bad "default mode did not repin surgically"; sed 's/^/      /' <<<"$changed"; fi
# and now it is green (idempotent: a second apply changes nothing more)
ran=$((ran + 1)); repin_check; rc1=$rc
before="$(cat "$WORK/repo/buildroot-external/package/hassio/addon-images.json")"
repin_apply; after="$(cat "$WORK/repo/buildroot-external/package/hassio/addon-images.json")"
if [[ $rc1 -eq 0 && "$before" == "$after" ]]; then
    ok "after repin, --check is green and a re-apply is a no-op (idempotent)"
else bad "not idempotent after repin (check rc=$rc1)"; fi

echo "== 3. canary store, release pin: PRERELEASE, NOT drift (agree with gate) =="
make_repo "1.2.0" "$IMAGE"; make_store "1.3.0-ga.1"
ran=$((ran + 1)); repin_check
if [[ $rc -eq 0 ]] && grep -qE 'PRERELEASE ga_hmvapp_addon' <<<"$out" \
   && ! grep -qE 'DRIFT ga_hmvapp_addon' <<<"$out"; then
    ok "repin --check treats a canary store as PRERELEASE, exits 0"
else bad "repin --check mishandled a canary store (rc=$rc)"; sed 's/^/      /' <<<"$out"; fi
ran=$((ran + 1)); gate_run
if grep -qE 'PRERELEASE.*ga_hmvapp_addon' <<<"$gout" && ! grep -qE 'FAIL.*ga_hmvapp_addon' <<<"$gout"; then
    ok "check-images.sh agrees: PRERELEASE, no FAIL"
else bad "gate disagrees on the canary case"; grep -iE 'hmvapp' <<<"$gout" | sed 's/^/      /'; fi
# default mode must NOT bake the canary — the release pin stays put
ran=$((ran + 1)); repin_apply
if [[ $rc -eq 0 && "$(pin_version)" == "1.2.0" ]]; then
    ok "default mode leaves the release pin — a canary is never auto-baked"
else bad "default mode changed the pin toward the canary (now $(pin_version))"; fi

echo "== 4. a numeric suffix is a revision, not a canary -> drift (z2m's 2.12.1-4) =="
make_repo "2.12.1" "$IMAGE"; make_store "2.12.1-4"
ran=$((ran + 1)); repin_check
if [[ $rc -ne 0 ]] && grep -qE 'DRIFT ga_hmvapp_addon' <<<"$out" && ! grep -qE 'PRERELEASE' <<<"$out"; then
    ok "repin --check calls a numeric-suffix drift a DRIFT, not a pre-release"
else bad "repin --check mistook a release revision for a canary (rc=$rc)"; sed 's/^/      /' <<<"$out"; fi
ran=$((ran + 1)); gate_run
if grep -qE 'FAIL.*ga_hmvapp_addon version mismatch' <<<"$gout"; then
    ok "check-images.sh agrees: it is drift"
else bad "gate disagrees on the revision case"; grep -iE 'hmvapp' <<<"$gout" | sed 's/^/      /'; fi

echo "== 5. a pin with NO store entry is fail-closed (the sonoff-class coverage bug) =="
# Realistic shape: one pin matches the store, one does not — exactly the sonoff
# situation (7 matched, 1 not). A single-missing-pin fixture would trip the
# zero-coverage guard instead, which is a different (also fail-closed) path.
mkdir -p "$WORK/repo/buildroot-external/package/hassio"
cat > "$WORK/repo/buildroot-external/package/hassio/addon-images.json" <<JSON
{
  "addons": {
    "ga_hmvapp_addon": { "image": "$IMAGE", "version": "1.2.0" },
    "ga_ghost":        { "image": "ghcr.io/greenautarky/ga_ghost-{arch}", "version": "1.0.0" }
  }
}
JSON
make_store "1.2.0"
ran=$((ran + 1)); repin_check
if [[ $rc -ne 0 ]] && grep -qE 'NO STORE ENTRY ga_ghost' <<<"$out"; then
    ok "repin --check fails closed and names the pin with no store entry"
else bad "repin --check did not fail closed on a missing store entry (rc=$rc)"; sed 's/^/      /' <<<"$out"; fi
ran=$((ran + 1)); repin_apply
if [[ $rc -ne 0 ]] && grep -qE 'no matching store entry' <<<"$out"; then
    ok "default mode also refuses (cannot repin what the store does not carry)"
else bad "default mode did not refuse a missing store entry (rc=$rc)"; sed 's/^/      /' <<<"$out"; fi
ran=$((ran + 1)); gate_run
if grep -qE 'has no matching addon in vibe_addons' <<<"$gout"; then
    ok "check-images.sh agrees: no matching addon in the store"
else bad "gate disagrees on the missing-entry case"; grep -iE 'ga_ghost|matching' <<<"$gout" | sed 's/^/      /'; fi

echo "== 6. --marker edits ONLY the version token, keeps the comment verbatim =="
make_repo "1.2.0" "$IMAGE" "BOSv1.3.0-rc14"; make_store "1.2.0"
ran=$((ran + 1))
out="$(REPO_ROOT="$WORK/repo" python3 "$REPIN" --store "$WORK/store" --marker BOSv1.3.0-rc99 2>&1)"; rc=$?
line="$(grep -E '^gaos_release:' "$WORK/repo/version.yaml")"
if [[ $rc -eq 0 && "$line" == 'gaos_release: BOSv1.3.0-rc99  # KEEP-THIS-COMMENT-VERBATIM operator edits this by hand' ]]; then
    ok "marker stamped rc14 -> rc99, trailing comment untouched"
else bad "marker edit was not surgical (rc=$rc): [$line]"; fi

echo "== 7. a marker that is not a BOS marker is refused, file untouched =="
make_repo "1.2.0" "$IMAGE" "BOSv1.3.0-rc14"; make_store "1.2.0"
ran=$((ran + 1)); before="$(cat "$WORK/repo/version.yaml")"
out="$(REPO_ROOT="$WORK/repo" python3 "$REPIN" --store "$WORK/store" --marker rc99 2>&1)"; rc=$?
after="$(cat "$WORK/repo/version.yaml")"
if [[ $rc -ne 0 && "$before" == "$after" ]] && grep -qiE 'does not look like a BOS release marker' <<<"$out"; then
    ok "a bad marker is rejected and version.yaml is left untouched"
else bad "a bad marker was not rejected cleanly (rc=$rc)"; sed 's/^/      /' <<<"$out"; fi

echo "== 8. --check and --marker together is refused (read-only vs write) =="
ran=$((ran + 1))
out="$(REPO_ROOT="$WORK/repo" python3 "$REPIN" --check --marker BOSv1.3.0-rc99 --store "$WORK/store" 2>&1)"; rc=$?
if [[ $rc -ne 0 ]] && grep -qiE 'read-only' <<<"$out"; then
    ok "--check + --marker is refused"
else bad "--check + --marker was not refused (rc=$rc)"; sed 's/^/      /' <<<"$out"; fi

echo "== 9. an empty store is not a pass (a check that inspected nothing proves nothing) =="
make_repo "1.2.0" "$IMAGE"
rm -rf "$WORK/store"; mkdir -p "$WORK/store"
git -C "$WORK/store" init -q -b main
git -C "$WORK/store" -c user.email=t@e -c user.name=t commit -q --allow-empty -m empty
ran=$((ran + 1)); repin_check
if [[ $rc -ne 0 ]] && grep -qiE 'no add-on entries found' <<<"$out"; then
    ok "an empty store is refused, not reported green"
else bad "an empty store was not refused (rc=$rc)"; sed 's/^/      /' <<<"$out"; fi

echo
if (( ran == 0 )); then echo "${RED}FATAL${NC} nothing evaluated"; exit 1; fi
if (( fails == 0 )); then
    printf '%srepin-addons selftest: %d/%d (red AND green proven; agrees with check-images.sh)%s\n' \
        "$GRN" "$ran" "$ran" "$NC"; exit 0
fi
printf '%srepin-addons selftest: %d of %d FAILED%s\n' "$RED" "$fails" "$ran" "$NC"; exit 1
