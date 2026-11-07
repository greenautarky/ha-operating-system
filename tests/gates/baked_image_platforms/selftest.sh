#!/usr/bin/env bash
# selftest.sh -- scripts/check-baked-image-platforms.sh (the LIVE script) goes red on a baked
# image whose config lacks the board's platform and green on a correct one (Odoo #1637).
# Fixtures: must-fail/ and must-pass/ hold image CONFIGS named <arch>-<what>.json; the first two
# are the REAL BOSv1.6.0-rc4 / rc2 Core configs (history stripped). Each is wrapped into an OCI
# archive (and the same into a docker-archive) in a throwaway images dir.
# Also proven: zero archives, an unreadable archive and a mixed dir (one bad among good) are RED;
# and the fetch script's platform_ok (patches/haos/0004, exported from the patched tree) rejects /
# accepts the same archives and re-fetches a stale cached one.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
GATE="$ROOT/scripts/check-baked-image-platforms.sh"
[ -x "$GATE" ] || { echo "FATAL: $GATE missing"; exit 1; }
for t in jq tar python3 sha256sum; do command -v $t >/dev/null || { echo "FATAL: $t missing"; exit 1; }; done
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fails=0; ran=0
ok()  { ran=$((ran+1)); echo "  ok    $1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); echo "  FAIL  $1"; }

# mkarchive KIND CONFIG.json OUT.tar   (KIND = oci | docker)
mkarchive() {
  python3 - "$1" "$2" "$3" <<'PY'
import hashlib, io, json, sys, tarfile
kind, cfgf, out = sys.argv[1:4]
cfg = open(cfgf, "rb").read(); cd = hashlib.sha256(cfg).hexdigest()
def add(t, n, d):
    ti = tarfile.TarInfo(n); ti.size = len(d); t.addfile(ti, io.BytesIO(d))
with tarfile.open(out, "w") as t:
    if kind == "oci":
        man = json.dumps({"schemaVersion": 2, "config": {"digest": "sha256:" + cd, "size": len(cfg)}, "layers": []}).encode()
        md = hashlib.sha256(man).hexdigest()
        add(t, "index.json", json.dumps({"schemaVersion": 2, "manifests": [{"digest": "sha256:" + md}]}).encode())
        add(t, "blobs/sha256/" + md, man); add(t, "blobs/sha256/" + cd, cfg)
    else:
        add(t, "manifest.json", json.dumps([{"Config": cd + ".json", "Layers": []}]).encode()); add(t, cd + ".json", cfg)
PY
}
run() { # DIR ARCH -> sets OUT, RC
  OUT="$("$GATE" --images-dir "$1" --arch "$2" 2>&1)"; RC=$?
}
cases=0
for verdict in must-fail must-pass; do
  for f in "$HERE/$verdict"/*.json; do
    cases=$((cases+1)); name="$(basename "$f" .json)"; arch="${name%%-*}"
    for kind in oci docker; do
      d="$W/$verdict-$name-$kind"; mkdir -p "$d"; mkarchive $kind "$f" "$d/ghcr.io_x_${name}@sha256_00.tar"
      run "$d" "$arch"
      if [ "$verdict" = must-fail ]; then
        [ "$RC" = 1 ] && grep -q ' 1 bad' <<<"$OUT" && ok "$verdict/$name ($kind) -> red" || bad "$verdict/$name ($kind) rc=$RC :: $OUT"
      else
        [ "$RC" = 0 ] && grep -q ' 0 bad' <<<"$OUT" && ok "$verdict/$name ($kind) -> green" || bad "$verdict/$name ($kind) rc=$RC :: $OUT"
      fi
    done
  done
done
[ "$cases" -ge 11 ] || bad "only $cases fixtures ran"
# fail closed
mkdir "$W/empty"; run "$W/empty" armv7; [ "$RC" = 1 ] && grep -q 'proves nothing' <<<"$OUT" && ok "zero archives -> red" || bad "zero archives rc=$RC :: $OUT"
run "$W/does-not-exist" armv7; [ "$RC" = 1 ] && ok "missing images dir -> red" || bad "missing dir rc=$RC"
mkdir "$W/junk"; echo notatar > "$W/junk/a.tar"; run "$W/junk" armv7; [ "$RC" = 1 ] && grep -q 'no readable image config' <<<"$OUT" && ok "unreadable archive -> red" || bad "junk rc=$RC :: $OUT"
mkdir "$W/mixed"; mkarchive oci "$HERE/must-pass/armv7-supervisor-v7.json" "$W/mixed/a.tar"; mkarchive oci "$HERE/must-fail/armv7-rc4-core-no-variant.json" "$W/mixed/b.tar"
run "$W/mixed" armv7; [ "$RC" = 1 ] && grep -q '2 archive(s), 1 bad' <<<"$OUT" && ok "one bad among good -> red" || bad "mixed rc=$RC :: $OUT"
run "$W/mixed" riscv; [ "$RC" = 2 ] && ok "unknown arch -> usage error" || bad "unknown arch rc=$RC"

# --- the fetch script (patch 0004): LIVE patched file, stub skopeo --------------------------------
if [ -d "$ROOT/haos/buildroot-external" ] && [ -x "$ROOT/scripts/apply-haos-patches.sh" ]; then
  FETCH="$W/fetch.sh"
  if "$ROOT/scripts/apply-haos-patches.sh" --cat buildroot-external/package/hassio/fetch-container-image.sh > "$FETCH" 2>"$W/cat.err" && [ -s "$FETCH" ] && grep -q '^platform_ok()' "$FETCH"; then
    chmod +x "$FETCH"; mkdir -p "$W/bin" "$W/dl" "$W/dst"
    cat > "$W/bin/skopeo" <<'SK'
#!/usr/bin/env bash
# stub: inspect -> digest; copy -> write the archive named by $STUB_CFG (kind oci)
if [ "$1" = inspect ]; then echo '{"Digest":"sha256:0000000000000000000000000000000000000000000000000000000000000001"}'; exit 0; fi
if [ "$1" = --version ]; then echo "skopeo version stub"; exit 0; fi
dest="${@: -1}"; dest="${dest#oci-archive:}"; dest="${dest%%.tar:*}.tar"
echo x >> "$STUB_LOG"; cp "$STUB_TAR" "$dest"
SK
    chmod +x "$W/bin/skopeo"
    echo '{"images":{"core":"ghcr.io/x/core-{arch}"},"core":"1.0"}' > "$W/version.json"
    mkarchive oci "$HERE/must-fail/armv7-rc4-core-no-variant.json" "$W/bad.tar"
    mkarchive oci "$HERE/must-pass/armv7-core-with-variant-v7.json" "$W/good.tar"
    fetch() { PATH="$W/bin:$PATH" STUB_TAR="$1" STUB_LOG="$W/stub.log" "$FETCH" armv7 tinker "$W/version.json" core "$W/dl" "$W/dst" >"$W/f.out" 2>&1; }
    F="$W/dl/ghcr.io_x_core-armv7_1.0@sha256_0000000000000000000000000000000000000000000000000000000000000001.tar"
    : > "$W/stub.log"; rm -f "$F"; fetch "$W/good.tar"
    [ $? = 0 ] && ls "$W/dst"/*.tar >/dev/null 2>&1 && ok "fetch: a correct archive is baked" || bad "fetch good: $(cat "$W/f.out")"
    rm -rf "$W/dst"/*; : > "$W/stub.log"; cp "$W/bad.tar" "$F"; fetch "$W/good.tar"
    [ $? = 0 ] && [ "$(wc -l < "$W/stub.log")" = 1 ] && grep -q 'discarding it' "$W/f.out" && ok "fetch: a stale cached archive without variant is discarded and fetched again" || bad "fetch stale cache: $(cat "$W/f.out")"
    rm -rf "$W/dst"/*; : > "$W/stub.log"; rm -f "$F"; fetch "$W/bad.tar"
    [ $? = 1 ] && grep -q 'refusing to bake' "$W/f.out" && ! ls "$W/dst"/*.tar >/dev/null 2>&1 && [ ! -e "$F" ] && ok "fetch: a fresh archive without variant stops the build" || bad "fetch bad: $(cat "$W/f.out")"
  else
    bad "fetch: cannot export the patched fetch script (patch 0004 missing?): $(cat "$W/cat.err")"
  fi
elif [ "${HAOS_PATCHES_REQUIRE_LIVE:-0}" = 1 ]; then bad "haos/ not checked out but required"
else echo "  skip  fetch-script cases: haos/ submodule not checked out"; fi
[ "$ran" -gt 0 ] || { echo "FAIL: zero cases"; exit 1; }
echo "$ran cases, $fails failed"; exit $((fails > 0))
