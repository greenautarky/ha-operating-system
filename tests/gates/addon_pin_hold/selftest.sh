#!/usr/bin/env bash
# =============================================================================
# selftest.sh — a declared hold may excuse a pin that is behind, and nothing else.
# =============================================================================
# WHY THIS EXISTS
# ---------------
# ga_build.sh runs scripts/check-images.sh with GA_SOURCE_DRIFT_STRICT=1, so a
# pin behind the newest published image fails the bake. On 2026-10-11 that was
# right for an accident and wrong for a decision: Thomas held ga_manager at
# 0.239.0 in BOSv1.5.0 while 0.248.0 was published, and the only escape was an
# environment variable that switches the whole check off for every add-on and
# leaves no trace in the repo.
#
# A hold is now DECLARED next to the pin ("hold": {"reason", "until"}). This
# suite proves the hold excuses exactly that drift and fails in every way a hold
# can rot: no reason, malformed date, expired, or open-ended (> 30 days).
#
# Runs the LIVE gate (scripts/check-images.sh), offline: a stub `skopeo` on PATH
# answers "image exists" and lists the tags given per case, stable.json is a
# local file, and the store is a git repo built on the spot.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
GATE="$ROOT/scripts/check-images.sh"
RED=$'\033[0;31m'; GRN=$'\033[0;32m'; NC=$'\033[0m'
fails=0; ran=0
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$NC" "$*"; fails=$((fails + 1)); }
ok()  { printf '  %sok%s    %s\n' "$GRN" "$NC" "$*"; }

[[ -x "$GATE" ]] || { echo "FATAL: $GATE missing or not executable"; exit 1; }
grep -q 'hold.reason' "$GATE" || { echo "FATAL: $GATE has no hold handling — extraction found nothing to test"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git required"; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
# skopeo stub: inspect always succeeds (images exist); list-tags prints $STUB_TAGS.
cat > "$WORK/bin/skopeo" <<'SH'
#!/bin/sh
case "$1" in
  list-tags) printf '{"Tags":[%s]}\n' "$STUB_TAGS" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$WORK/bin/skopeo"

cat > "$WORK/stable.json" <<'JSON'
{"supervisor":"0","core":"0","cli":"0","dns":"0","audio":"0","multicast":"0",
 "observer":"0",
 "images":{"supervisor":"localhost:1/none-{arch}","core":"localhost:1/none-{arch}-{machine}",
           "cli":"localhost:1/none-{arch}","dns":"localhost:1/none-{arch}",
           "audio":"localhost:1/none-{arch}","multicast":"localhost:1/none-{arch}",
           "observer":"localhost:1/none-{arch}"}}
JSON

TODAY="2026-10-11"
make_pin() { # make_pin <version> <hold-json or "">
    mkdir -p "$WORK/repo/buildroot-external/package/hassio"
    local hold=""; [ -n "$2" ] && hold=", \"hold\": $2"
    cat > "$WORK/repo/buildroot-external/package/hassio/addon-images.json" <<JSON
{ "addons": { "ga_manager": {
    "image": "ghcr.io/greenautarky/ga_manager-{arch}", "version": "$1"$hold } } }
JSON
}
make_store() { # store in lockstep with the pin, so only the drift verdict varies
    rm -rf "$WORK/store"; mkdir -p "$WORK/store/ga_manager"
    printf 'name: "GA Manager"\nversion: "%s"\nslug: "ga_manager"\nimage: ghcr.io/greenautarky/ga_manager-{arch}\n' "$1" \
        > "$WORK/store/ga_manager/config.yaml"
    git -C "$WORK/store" init -q -b main
    git -C "$WORK/store" -c user.email=t@e -c user.name=t add -A
    git -C "$WORK/store" -c user.email=t@e -c user.name=t commit -qm store
}
run_case() { # run_case <label> <pin> <tags> <hold-json> <expect-exit> <expect-regex>
    local label="$1" pin="$2" tags="$3" hold="$4" want_rc="$5" expect="$6" out rc
    make_pin "$pin" "$hold"; make_store "$pin"
    ran=$((ran + 1))
    out="$(PATH="$WORK/bin:$PATH" STUB_TAGS="$tags" GA_TODAY="$TODAY" GA_SOURCE_DRIFT_STRICT=1 \
           REPO_ROOT="$WORK/repo" VIBE_ADDONS_REPO_URL="$WORK/store" VIBE_ADDONS_REPO_REF=main \
           "$GATE" "$WORK/stable.json" 2>&1)"; rc=$?
    if [ "$rc" != "$want_rc" ]; then
        bad "$label — exit $rc, expected $want_rc"; grep -aE 'ga_manager|HOLD|DRIFT|Held|ERROR' <<<"$out" | sed 's/^/          /' | head -6; return
    fi
    if ! grep -qE "$expect" <<<"$out"; then
        bad "$label — expected /$expect/"; grep -aE 'ga_manager|HOLD|DRIFT|Held' <<<"$out" | sed 's/^/          /' | head -6; return
    fi
    ok "$label"
}

T='"0.239.0","0.248.0"'
echo "== must PASS (a hold excuses exactly this drift) =="
run_case "pin == newest, no hold -> OK" \
    "0.248.0" "$T" "" 0 'OK.*ga_manager pinned 0.248.0 == newest'
run_case "pin behind, valid hold -> HOLD, bake passes" \
    "0.239.0" "$T" '{"reason":"held for BOSv1.5.0 (Thomas 2026-10-11)","until":"2026-10-25"}' 0 'HOLD.*ga_manager.*held until 2026-10-25'
run_case "valid hold is counted in the summary" \
    "0.239.0" "$T" '{"reason":"r","until":"2026-10-11"}' 0 'Held: +1 '
run_case "hold on an up-to-date pin -> OK + note to remove it" \
    "0.248.0" "$T" '{"reason":"r","until":"2026-10-20"}' 0 'NOTE.*ga_manager carries a hold but is not behind'

echo "== must FAIL (drift without a valid hold is still drift) =="
run_case "pin behind, no hold -> DRIFT, bake fails" \
    "0.239.0" "$T" "" 1 'DRIFT.*ga_manager pinned 0.239.0 but 0.248.0'
run_case "hold without reason -> invalid, fails" \
    "0.239.0" "$T" '{"until":"2026-10-20"}' 1 'HOLD INVALID.*no reason'
run_case "hold with malformed date -> invalid, fails" \
    "0.239.0" "$T" '{"reason":"r","until":"next week"}' 1 'HOLD INVALID.*not YYYY-MM-DD'
run_case "expired hold -> invalid, fails" \
    "0.239.0" "$T" '{"reason":"r","until":"2026-10-10"}' 1 'HOLD INVALID.*expired on 2026-10-10'
run_case "open-ended hold (> 30 days) -> invalid, fails" \
    "0.239.0" "$T" '{"reason":"r","until":"2026-12-31"}' 1 'HOLD INVALID.*more than 30 days'

echo
echo "ran $ran, failed $fails"
[ "$ran" -gt 0 ] || { echo "FATAL: no case ran"; exit 1; }
[ "$fails" -eq 0 ]
