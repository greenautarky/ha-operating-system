#!/usr/bin/env bash
# =============================================================================
# selftest.sh — a pinned add-on that is not in the image must go RED.
# =============================================================================
# The check this exercises replaced one that could not fail in the cases that
# mattered: it globbed the pin's slug, and a miss counted as SKIP while the
# suite still printed a pass line. Measured against the 2026-08-18 bake,
# `sonoff_dongle_flasher` had never once been checked (pin key uses underscores,
# tar name uses dashes), and a pin whose image was never fetched skipped the same
# way — the exact scenario that would have hidden a missing ga_hmvapp_addon.
#
# So both directions are fixtures here. must-fail: every way a pin can fail to
# be in the image. must-pass: a complete image, and the dash/underscore add-on,
# because a check that flags everything gets overridden by reflex and that is a
# slower way of having no check at all.
#
# Runs with --no-registry so nothing here depends on the network or on
# credentials: what is under test is the presence-and-coverage logic, and a
# registry lookup could only make the result less deterministic. Digest
# freshness against GHCR is the build suite's job, on a real bake.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
GATE="$ROOT/scripts/check-baked-addon-images.sh"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; NC=$'\033[0m'
fails=0; ran=0

bad() { printf '  %sFAIL%s  %s\n' "$RED" "$NC" "$*"; fails=$((fails + 1)); }
ok()  { printf '  %sok%s    %s\n' "$GRN" "$NC" "$*"; }

[[ -x "$GATE" ]] || { echo "FATAL: $GATE missing or not executable"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

D="$WORK/images"

# A digest is 64 hex chars and the script insists on that, so the fixtures use
# real-shaped ones rather than "abc".
d1="1111111111111111111111111111111111111111111111111111111111111111"
d2="2222222222222222222222222222222222222222222222222222222222222222"

# The pin file. Deliberately includes the two shapes that broke the old check:
# `mosquitto`, whose key does not appear in its own image name, and
# `sonoff_dongle_flasher`, whose tar spells the name with dashes and lives under
# a different org.
write_pins() {
    cat > "$WORK/pins.json" <<'JSON'
{
  "addons": {
    "ga_manager": {
      "image": "ghcr.io/greenautarky/ga_manager-{arch}",
      "version": "0.116.0"
    },
    "mosquitto": {
      "image": "ghcr.io/greenautarky/ga_mosquitto-{arch}",
      "version": "7.1.3"
    },
    "sonoff_dongle_flasher": {
      "image": "ghcr.io/ihost-open-source-project/hassio-ihost-sonoff-dongle-flasher-{arch}",
      "version": "1.3.4"
    }
  }
}
JSON
}

# Exactly the filenames the 2026-08-18 bake produced, modulo version/digest.
write_images() {
    rm -rf "$D"; mkdir -p "$D"
    : > "$D/ghcr.io_greenautarky_ga_manager-armv7_0.116.0@sha256_${d1}.tar"
    : > "$D/ghcr.io_greenautarky_ga_mosquitto-armv7_7.1.3@sha256_${d1}.tar"
    : > "$D/ghcr.io_ihost-open-source-project_hassio-ihost-sonoff-dongle-flasher-armv7_1.3.4@sha256_${d1}.tar"
    # Unrelated tars, as in a real bake — they must not be mistaken for a pin.
    : > "$D/ghcr.io_home-assistant_armv7-hassio-cli_2025.09.0@sha256_${d2}.tar"
    : > "$D/ghcr.io_greenautarky_armv7-hassio-supervisor_2025.11.4.6@sha256_${d2}.tar"
}

run() { # run <expect-rc> <label> <expect-regex-or-empty> <forbid-regex-or-empty>
    local want="$1" label="$2" expect="$3" forbid="$4" out rc
    ran=$((ran + 1))
    out="$("$GATE" --images-dir "$D" --pins "$WORK/pins.json" --no-registry 2>&1)"
    rc=$?
    if [[ "$rc" -ne "$want" ]]; then
        bad "$label — expected rc=$want, got rc=$rc"
        sed 's/^/          /' <<<"$out" | head -6
        return
    fi
    if [[ -n "$expect" ]] && ! grep -qE "$expect" <<<"$out"; then
        bad "$label — expected /$expect/ in the output"
        sed 's/^/          /' <<<"$out" | head -6
        return
    fi
    if [[ -n "$forbid" ]] && grep -qE "$forbid" <<<"$out"; then
        bad "$label — output must NOT contain /$forbid/"
        sed 's/^/          /' <<<"$out" | head -6
        return
    fi
    ok "$label"
}

echo "== must-pass: a complete image is not flagged =="

# The baseline. Without it, a check that fails everything would pass every
# must-fail case below and look rigorous.
write_pins; write_images
run 0 "all three pins baked -> pass, 3/3 counted" '3/3 pins present' 'FAIL'

# The regression that started this. Under the old slug glob this add-on was
# silently skipped on every bake; the pass line has to name it as counted, and
# 3/3 above is what proves it — but assert it directly too, because "3/3" would
# also hold if some other pin were double-counted.
write_pins; write_images
ran=$((ran + 1))
out="$("$GATE" --images-dir "$D" --pins "$WORK/pins.json" --no-registry 2>&1)"
if grep -qE '3/3 pins present' <<<"$out" && ! grep -qiE 'sonoff.*(skip|FAIL)' <<<"$out"; then
    ok "the dash/underscore add-on is CHECKED, not skipped"
else
    bad "sonoff_dongle_flasher is still not being counted"
    sed 's/^/          /' <<<"$out" | head -6
fi

echo "== must-fail: every way a pin can be absent =="

# The hmvapp scenario: pinned, never fetched. This is the whole reason the
# script exists, and the old check called it "skipped".
write_pins; write_images
rm -f "$D"/*sonoff*
run 1 "pinned but not baked -> FAIL, named" 'FAIL: sonoff_dongle_flasher 1.3.4 is pinned but NOT baked' ''

# A pin bumped without a rebake. The tar is there, for the OLD version — a
# prefix match that ignored the version would call this baked.
write_pins; write_images
mv "$D/ghcr.io_greenautarky_ga_manager-armv7_0.116.0@sha256_${d1}.tar" \
   "$D/ghcr.io_greenautarky_ga_manager-armv7_0.115.0@sha256_${d1}.tar"
run 1 "tar is for the previous version -> FAIL" 'FAIL: ga_manager 0.116.0 is pinned but NOT baked' ''

# Two tars for one pin: a stale one left behind next to a fresh one. Picking
# `head -1` would report whichever sorted first as the baked digest, which is a
# coin toss dressed up as a measurement.
write_pins; write_images
: > "$D/ghcr.io_greenautarky_ga_manager-armv7_0.116.0@sha256_${d2}.tar"
run 1 "two tars for one pin -> FAIL (ambiguous)" 'FAIL: ga_manager 0.116.0 matches 2 tars' ''

# A filename with no usable digest. Silently treating that as verified would be
# the old failure mode with extra steps.
write_pins; write_images
mv "$D/ghcr.io_greenautarky_ga_mosquitto-armv7_7.1.3@sha256_${d1}.tar" \
   "$D/ghcr.io_greenautarky_ga_mosquitto-armv7_7.1.3@sha256_nothex.tar"
run 1 "unreadable digest in the filename -> FAIL" 'FAIL: mosquitto — cannot read a digest' ''

# Fail closed on zero. An empty pin file means the jq path changed or the file
# moved; reporting success over nothing is how a dead check stays green.
write_images
echo '{"addons":{}}' > "$WORK/pins.json"
run 1 "no pins at all -> FAIL (not a pass)" 'no add-on pins found' ''

# A pin file the script cannot parse at all must fail the same way, not be
# treated as "zero pins, fine".
write_images
echo 'this is not json' > "$WORK/pins.json"
run 1 "unparseable pin file -> FAIL" 'no add-on pins found' ''

echo "== must-fail: a missing images dir is not a skip =="
write_pins
ran=$((ran + 1))
out="$("$GATE" --images-dir "$WORK/nope" --pins "$WORK/pins.json" --no-registry 2>&1)"; rc=$?
if [[ "$rc" -eq 1 ]] && grep -qE 'images dir does not exist' <<<"$out"; then
    ok "absent images dir -> FAIL"
else
    bad "absent images dir gave rc=$rc"
    sed 's/^/          /' <<<"$out" | head -4
fi

echo
if (( ran == 0 )); then echo "${RED}FATAL${NC} nothing evaluated"; exit 1; fi
if (( fails == 0 )); then
    printf '%sbaked add-on images selftest: %d/%d%s\n' "$GRN" "$ran" "$ran" "$NC"; exit 0
fi
printf '%sbaked add-on images selftest: %d of %d FAILED%s\n' "$RED" "$fails" "$ran" "$NC"; exit 1
