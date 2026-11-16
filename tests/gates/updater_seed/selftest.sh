#!/usr/bin/env bash
# The baked updater.json (Odoo #2065, F5). A fresh device has not fetched the
# channel: every version+image the line bakes must already be in the seed, else
# the Supervisor resolves plugins to the UPSTREAM names, which are not baked,
# and without internet PluginBase.install() retries forever (cli never up).
#
# Runs the LIVE buildroot-external/package/hassio/gen-updater-json.sh against the
# real board fixtures (tests/gates/build_tests_board_matrix/fixtures/<board>:
# version.json + the baked image list images.txt) and judges the output against
# PINNED expectations (pins/<board>.json, literals - never derived from the
# artifact under test). The fixtures are static: the pins change only when a
# fixture is re-measured.
#   must-pass : ihost and dsgw210 seeds equal their pins
#   must-fail : the rc13 Core-only seed, a plugin on its upstream image name, a
#               plugin off its pinned version (the checker flags them); and the
#               helper refuses: plugin missing, "latest", upstream image name,
#               plugin not baked
#   wiring    : the create-data-partition.sh the build sees (patches applied)
#               calls the helper and writes its output to updater.json
# Zero cases = FAIL.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
helper="$root/buildroot-external/package/hassio/gen-updater-json.sh"
fx="$root/tests/gates/build_tests_board_matrix/fixtures"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
n=0 bad=0
ok()  { n=$((n+1)); echo "  ok    $1"; }
bad() { n=$((n+1)); bad=1; echo "  FAIL  $1"; }

# check_seed <seed.json> <pins.json>: every pinned key must be present and equal
check_seed() { jq -e --slurpfile p "$2" '. as $s | $p[0] as $p | ($p | del(.image)) as $v
  | ([$v | to_entries[] | select($s[.key] != .value)] | length) == 0
    and ([$p.image | to_entries[] | select($s.image[.key] != .value)] | length) == 0' "$1" > /dev/null 2>&1; }

mkimgs() { # <images.txt> <dir>
  mkdir -p "$2"; while IFS= read -r f; do [ -n "$f" ] && : > "$2/$f"; done < "$1"; }

have_helper=1
[ -x "$helper" ] || { bad "helper missing or not executable: $helper"; have_helper=0; }

for b in ihost dsgw210; do
  [ "$have_helper" = 1 ] || { bad "must-pass: $b seed (no helper)"; continue; }
  d="$tmp/$b"; mkimgs "$fx/$b/images.txt" "$d/images"
  ch=$(jq -r .channel "$here/pins/$b.json")
  if "$helper" "$fx/$b/version.json" "$d/images" "$ch" > "$d/updater.json" 2> "$d/err" && check_seed "$d/updater.json" "$here/pins/$b.json"; then
    ok "must-pass: $b seed carries every pinned version+image"
  else bad "must-pass: $b seed differs from its pins"; cat "$d/err" "$d/updater.json" 2>/dev/null | sed 's/^/        /'; fi
done

for f in "$here"/must-fail/*.json; do
  b=ihost; if check_seed "$f" "$here/pins/$b.json"; then bad "must-fail/$(basename "$f"): checker accepted it"; else ok "must-fail: checker flags $(basename "$f")"; fi
done

refuse() { # label want-text version.json images-dir
  local out rc; out=$("$helper" "$3" "$4" stable 2>&1 >/dev/null); rc=$?
  if [ "$rc" -ne 0 ] && grep -qF -- "$2" <<<"$out"; then ok "must-fail: helper refuses $1"; else bad "must-fail: helper $1 (rc=$rc, wanted '$2'): $out"; fi; }
ih="$tmp/ihost/images"
if [ "$have_helper" = 1 ]; then
jq 'del(.cli)' "$fx/ihost/version.json" > "$tmp/no-cli.json";           refuse "a missing plugin version" "cli version" "$tmp/no-cli.json" "$ih"
jq '.dns = "latest"' "$fx/ihost/version.json" > "$tmp/latest.json";      refuse "a plugin on latest" "dns version" "$tmp/latest.json" "$ih"
jq '.images.audio = "homeassistant/{arch}-hassio-audio"' "$fx/ihost/version.json" > "$tmp/up.json"; refuse "an upstream plugin image" "not a greenautarky image" "$tmp/up.json" "$ih"
mkdir -p "$tmp/nobake"; grep -v 'hassio-observer' "$fx/ihost/images.txt" > "$tmp/nobake.txt"; mkimgs "$tmp/nobake.txt" "$tmp/nobake"
refuse "a plugin that is not baked" "observer" "$fx/ihost/version.json" "$tmp/nobake"
else for _ in 1 2 3 4; do bad "must-fail: helper refusal case (no helper)"; done; fi

# wiring: the script the build runs must use the helper (reachability, rule 11)
if cdp="$("$root/scripts/apply-haos-patches.sh" --cat buildroot-external/package/hassio/create-data-partition.sh 2>"$tmp/cat.err")"; then
  if grep -q 'gen-updater-json.sh' <<<"$cdp" && grep -E 'gen-updater-json.sh' <<<"$cdp" | grep -q 'updater.json'; then
    ok "wiring: create-data-partition.sh (as built) writes updater.json from gen-updater-json.sh"
  else bad "wiring: create-data-partition.sh (as built) does not seed updater.json via gen-updater-json.sh"; fi
else bad "wiring: cannot read create-data-partition.sh as the build sees it: $(cat "$tmp/cat.err")"; fi

[ "$n" -ge 10 ] || { echo "FAIL: only $n cases inspected (expected >= 10)"; exit 1; }
echo "$n cases inspected"
exit "$bad"
