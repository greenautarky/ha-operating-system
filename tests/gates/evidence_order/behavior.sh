#!/usr/bin/env bash
# behavior.sh — run the LIVE collect_build_evidence (extracted from scripts/ga_build.sh)
# and the LIVE collect-release-evidence.sh against fixture build trees (Odoo #1946).
#   must-pass : fresh files carrying this build's id -> evidence filed
#   must-flag : stale sbom-containers.json / stale MANIFEST.txt / missing file -> nothing filed
#   collector : a failed collection leaves NO partial destination directory
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIVE="${EVIDENCE_ORDER_LIVE:-$ROOT/scripts/ga_build.sh}"
COLL="${EVIDENCE_ORDER_COLLECTOR:-$ROOT/scripts/ops/collect-release-evidence.sh}"
fn="$(awk '/^collect_build_evidence\(\) *\{/{f=1} f{print} f&&/^\}/{exit}' "$LIVE")"
[[ -n "$fn" ]] || { echo "ERROR (could not check): collect_build_evidence not found in $LIVE" >&2; exit 2; }
[[ -x "$COLL" ]] || { echo "ERROR (could not check): $COLL not executable" >&2; exit 2; }
T=20260101000000; OLD=20250101000000; VER=BOSv1.0.0-rc1
fails=0 ran=0
mk() { # <dir> <manifest-build-id> <sbom-build-id> -> OUT tree
  mkdir -p "$1/images/configs"
  printf 'Build ID:        %s\n' "$2" > "$1/images/configs/MANIFEST.txt"
  echo '{"repositories":{"a":{}},"packages":{}}' > "$1/images/configs/source-pins.json"
  printf '{\n  "build_id": "%s",\n  "containers": []\n}\n' "$3" > "$1/images/sbom-containers.json"
}
run_fn() { # <OUT> <evroot> ; version.yaml fixture
  ( eval "$fn"; SCRIPT_DIR="$2/sd/scripts"; OUT="$1"; GA_RELEASE_KEY=gaos_release; GA_BUILD_TIMESTAMP=$T
    GA_EVIDENCE_ROOT="$2/ev"; collect_build_evidence ) 2>&1
}
setup() { d="$(mktemp -d)"; mkdir -p "$d/sd/scripts"; ln -s "$ROOT/scripts/ops" "$d/sd/scripts/ops"
  echo "gaos_release: $VER" > "$d/sd/version.yaml"; }
expect() { # <label> <want filed|none> <dir>
  ran=$((ran+1)); local got=none; [[ -s "$3/ev/$T/$VER/EVIDENCE.md" ]] && got=filed
  if [[ "$got" == "$2" ]]; then echo "  ok    $1 ($got)"; else echo "  FAIL  $1: expected $2, got $got"; fails=$((fails+1)); fi
}
setup; mk "$d/o" $T $T;   out="$(run_fn "$d/o" "$d")"; expect "must-pass fresh build files" filed "$d"; rm -rf "$d"
setup; mk "$d/o" $T $OLD; out="$(run_fn "$d/o" "$d")"; expect "must-flag stale sbom-containers.json" none "$d"
  grep -q "ERROR" <<<"$out" || { echo "  FAIL  no ERROR printed for stale sbom"; fails=$((fails+1)); }; rm -rf "$d"
setup; mk "$d/o" $OLD $T; out="$(run_fn "$d/o" "$d")"; expect "must-flag stale MANIFEST.txt" none "$d"; rm -rf "$d"
setup; mk "$d/o" $T $T; rm "$d/o/images/sbom-containers.json"; out="$(run_fn "$d/o" "$d")"; expect "must-flag missing sbom-containers.json" none "$d"; rm -rf "$d"
# collector: failure must not leave a partial destination
setup; mk "$d/o" $T $T; rm "$d/o/images/sbom-containers.json"; "$COLL" "$d/o" $VER "$d/dest" >/dev/null 2>&1; rc=$?; ran=$((ran+1))
if [[ $rc -ne 0 && ! -e "$d/dest/$VER" ]]; then echo "  ok    collector failure leaves no partial dir (rc=$rc)"; else echo "  FAIL  collector rc=$rc, partial dir: $(ls "$d/dest/$VER" 2>&1 | tr '\n' ' ')"; fails=$((fails+1)); fi; rm -rf "$d"
[[ $ran -ge 5 ]] || { echo "ERROR (could not check): only $ran case(s)" >&2; exit 2; }
echo "behavior: $ran cases ran, $fails failed"; [[ $fails -eq 0 ]]
