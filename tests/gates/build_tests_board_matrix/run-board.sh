#!/bin/bash
# run-board.sh BOARD WORKDIR [RELEASE] -- build the BOARD fixture (make-fixture.sh) and run the LIVE
# build-test runner on it, the way ga_build.sh does (GA_BOARD exported, OUT inside the source tree).
# Only the NETWORK is replaced, never the runner or its checkers:
#   skopeo  the registry: answers with the digest of the baked tar when asked for the platform the
#           tar was pulled for, a different one for the other platform (so a check that asks the
#           wrong platform sees a stale image -- the DSGW dev4 VER-09 defect)
#   curl    the haos-version channel files: stable.json = the iHost bake's channel file, dev.json =
#           the DSGW-210 bake's (both captured from the real bakes)
# Prints the runner output, colour-stripped. Env: RUNNER (default: this checkout's runner).
set -u
BOARD="$1"; W="$2"; REL="${3:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="$("$HERE/make-fixture.sh" "$BOARD" "$W" | tail -1)" || { echo "run-board: fixture build failed" >&2; exit 2; }
if [ -z "$REL" ]; then
  REL="$(jq -r .ga_release "$HERE/fixtures/$BOARD/version.json")"
fi
mkdir -p "$W/bin"
IMG="$OUT/build/hassio-1.0.0/images"
cat > "$W/bin/skopeo" <<SK
#!/bin/bash
ref="\${*: -1}"; ref="\${ref#docker://}"; pre="\${ref//\\//_}"; pre="\${pre//:/_}"
f="\$(ls "$IMG/\${pre}@sha256_"*.tar 2>/dev/null | head -n 1)"; [ -n "\$f" ] || exit 1
dg="\${f##*sha256_}"; dg="\${dg%.tar}"
case "\$*" in *"--override-arch arm64"*) plat=aarch64 ;; *"--override-arch arm "*) plat=armv7 ;; *) plat=none ;; esac
case "\$f" in *aarch64*) have=aarch64 ;; *) have=armv7 ;; esac
[ "\$plat" = "\$have" ] || dg="0\${dg:1}"
echo "{\"Digest\":\"sha256:\$dg\"}"
SK
cat > "$W/bin/curl" <<CU
#!/bin/bash
case "\$*" in
  *stable.json*) jq 'del(.ga_release)' "$HERE/fixtures/ihost/version.json" ;;
  *dev.json*)    jq 'del(.ga_release)' "$HERE/fixtures/dsgw210/version.json" ;;
  *) exit 22 ;;
esac
CU
chmod +x "$W/bin/skopeo" "$W/bin/curl"
PATH="$W/bin:$PATH" GA_BOARD="$BOARD" GA_RELEASE="$REL" BR2EXT_NETBIRD="$W/src/buildroot-external" BUILDROOT_DIR="$W/buildroot" \
  bash "${RUNNER:-$W/src/tests/ga_tests/run_build_tests.sh}" "$OUT" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
