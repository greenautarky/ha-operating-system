#!/usr/bin/env bash
# selftest.sh -- scripts/check-clean-bake.sh (the LIVE script) goes red on a reused output tree
# that would ship stale inputs and green on a fresh one.
#
#  bootscr   images/boot.scr must embed the CURRENT uboot-boot.ush (2026-11-26: update bakes shipped
#            a boot.scr from before the VCCIO5 change; host-uboot-tools was never rebuilt).
#            Pinned pair fixtures/real-mkimage.{scr,ush} = a boot.scr written by the real mkimage
#            (read from the builder) and the source it was made from. The selftest's own mkimage
#            writer is proven byte-identical to that real file first, so the stale/fresh cases built
#            with it are not a guess about the format. Stale = the pre-optionB source's boot.scr
#            checked against the current source.
#   patchdirs a patches/<pkg>/<version>/ directory without a patch shadows <pkg>/'s patches.
#            must-fail/ and must-pass/ hold tree specs: `mkdir PATH` | `file PATH`.
# Also: the --out path (BR2_EXTERNAL expansion from .config/.br2-external.mk), exit 2 on inputs the
# check cannot read (fail closed), the live iHost patch dirs (must be green) and the live iHost +
# DSGW boot scripts (a boot.scr built from them is green, from them plus one byte is red).
# Not proven here: that Buildroot really regenerates boot.scr on `host-uboot-tools-rebuild`.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
GATE="$ROOT/scripts/check-clean-bake.sh"
FX="$HERE/fixtures"
[[ -x "$GATE" ]] || { echo "FATAL: $GATE missing or not executable"; exit 1; }
command -v python3 >/dev/null || { echo "FATAL: python3 missing"; exit 1; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fails=0; ran=0
ok()  { ran=$((ran+1)); echo "  ok    $1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); echo "  FAIL  $1"; }
run() { OUT="$("$GATE" "$@" 2>&1)"; RC=$?; }
expect() { # NAME WANT_RC [GREP]  (uses RC/OUT of the last run)
  if [[ "$RC" == "$2" ]] && { [[ -z "${3:-}" ]] || grep -q -- "$3" <<<"$OUT"; }; then ok "$1 -> rc $2"; else bad "$1 rc=$RC (want $2) :: $OUT"; fi
}

cat > "$W/mk.py" <<'PY'
# mk.py SRC DST [TIME] -- write a U-Boot legacy script image the way mkimage -T script does
import struct, sys, zlib
src = open(sys.argv[1], "rb").read()
ts = int(sys.argv[3]) if len(sys.argv) > 3 else 0
data = struct.pack(">II", len(src), 0) + src
dcrc = zlib.crc32(data) & 0xFFFFFFFF
hdr = struct.pack(">IIIIIIIBBBB32s", 0x27051956, 0, ts, len(data), 0, 0, dcrc, 5, 2, 6, 0, b"")
hcrc = zlib.crc32(hdr) & 0xFFFFFFFF
hdr = hdr[:4] + struct.pack(">I", hcrc) + hdr[8:]
open(sys.argv[2], "wb").write(hdr + data)
PY
mk() { python3 -I "$W/mk.py" "$@"; }

echo "== mkimage writer vs the REAL mkimage output =="
REAL_TS="$(python3 -I -c 'import struct,sys;print(struct.unpack(">I",open(sys.argv[1],"rb").read()[8:12])[0])' "$FX/real-mkimage.scr")"
mk "$FX/real-mkimage.ush" "$W/rebuilt.scr" "$REAL_TS"
cmp -s "$W/rebuilt.scr" "$FX/real-mkimage.scr" && ok "writer reproduces the real mkimage file byte for byte" || bad "writer differs from the real mkimage file (format assumption wrong)"

echo "== bootscr =="
run bootscr --boot-scr "$FX/real-mkimage.scr" --source "$FX/real-mkimage.ush"; expect "real mkimage boot.scr vs its source (fresh)" 0 "OK "
mk "$FX/pre-vccio5-optionB.ush" "$W/stale.scr"
run bootscr --boot-scr "$W/stale.scr" --source "$FX/real-mkimage.ush"; expect "boot.scr from the pre-optionB source vs the current source (STALE)" 1 "OLDER"
cp "$FX/real-mkimage.ush" "$W/plus.ush"; printf '\n' >> "$W/plus.ush"
run bootscr --boot-scr "$FX/real-mkimage.scr" --source "$W/plus.ush"; expect "source gained one byte (STALE)" 1 "OLDER"
sed 's/ga_vccio5/ga_vccio6/' "$FX/real-mkimage.ush" > "$W/same-len.ush"
run bootscr --boot-scr "$FX/real-mkimage.scr" --source "$W/same-len.ush"; expect "same length, different text (STALE)" 1 "OLDER"
head -c 3000 "$FX/real-mkimage.scr" > "$W/trunc.scr"
run bootscr --boot-scr "$W/trunc.scr" --source "$FX/real-mkimage.ush"; expect "truncated boot.scr" 1 "not a readable"
head -c 7284 /dev/zero > "$W/zero.scr"
run bootscr --boot-scr "$W/zero.scr" --source "$FX/real-mkimage.ush"; expect "not a script image" 1 "not a readable"
run bootscr --boot-scr "$W/absent.scr" --source "$FX/real-mkimage.ush" --require; expect "boot.scr missing after the build (--require)" 1 "does not exist"
run bootscr --boot-scr "$W/absent.scr" --source "$FX/real-mkimage.ush"; expect "boot.scr missing before the first build (no --require)" 0 "first build"
: > "$W/empty.ush"
run bootscr --boot-scr "$FX/real-mkimage.scr" --source "$W/empty.ush"; expect "empty source = cannot run" 2 "FAIL"
run bootscr --boot-scr "$FX/real-mkimage.scr" --source "$W/nonexistent.ush"; expect "missing source = cannot run" 2 "FAIL"

echo "== bootscr --out (source resolved from .config + .br2-external.mk) =="
O="$W/out"; mkdir -p "$O/images" "$W/ext/board"
cp "$FX/real-mkimage.ush" "$W/ext/board/uboot-boot.ush"; cp "$FX/real-mkimage.scr" "$O/images/boot.scr"
cat > "$O/.config" <<EOF
BR2_PACKAGE_HOST_UBOOT_TOOLS_BOOT_SCRIPT=y
BR2_PACKAGE_HOST_UBOOT_TOOLS_BOOT_SCRIPT_SOURCE="\$(BR2_EXTERNAL_IHOST_PATH)/board/uboot-boot.ush"
EOF
printf 'export BR2_EXTERNAL_IHOST_PATH = %s\n' "$W/ext" > "$O/.br2-external.mk"
run bootscr --out "$O" --require; expect "--out, fresh boot.scr" 0 "OK "
cp "$W/stale.scr" "$O/images/boot.scr"
run bootscr --out "$O" --require; expect "--out, stale boot.scr" 1 "OLDER"
cp "$FX/real-mkimage.scr" "$O/images/boot.scr"; printf 'export BR2_EXTERNAL_OTHER_PATH = /x\n' > "$O/.br2-external.mk"
run bootscr --out "$O" --require; expect "--out, unresolvable BR2_EXTERNAL name = cannot run" 2 "FAIL"
printf 'BR2_PACKAGE_HOST_UBOOT_TOOLS_BOOT_SCRIPT=n\n' > "$O/.config"
run bootscr --out "$O" --require; expect "--out, board without a boot script" 0 "nothing to compare"

echo "== bootscr on the LIVE sources =="
for u in buildroot-ihost/board/sonoff/ihost/uboot-boot.ush buildroot-dsgw210/board/dusun/dsgw210/uboot-boot.ush; do
  [[ -s "$ROOT/$u" ]] || { bad "live source $u missing"; continue; }
  mk "$ROOT/$u" "$W/live.scr"
  run bootscr --boot-scr "$W/live.scr" --source "$ROOT/$u"; expect "live $u: boot.scr built from it" 0 "OK "
  cp "$ROOT/$u" "$W/live-mut.ush"; echo "# mutation" >> "$W/live-mut.ush"
  run bootscr --boot-scr "$W/live.scr" --source "$W/live-mut.ush"; expect "live $u: source changed after the boot.scr was built" 1 "OLDER"
done

echo "== patchdirs =="
build() { # SPEC DIR
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*) ;;
      mkdir\ *) mkdir -p "$2/${line#mkdir }" ;;
      file\ *)  mkdir -p "$(dirname "$2/${line#file }")"; echo x > "$2/${line#file }" ;;
      *) echo "FATAL: bad directive '$line' in $1"; exit 1 ;;
    esac
  done < "$1"
}
cases=0
for verdict in must-fail must-pass; do
  for f in "$HERE/patchdirs/$verdict"/*.txt; do
    cases=$((cases+1)); n="$(basename "$f" .txt)"; d="$W/pd-$verdict-$n"; mkdir -p "$d"; build "$f" "$d"
    run patchdirs "$d"
    if [[ "$verdict" == must-fail ]]; then expect "$verdict/$n" 1 "BAD "; else expect "$verdict/$n" 0 " 0 problem"; fi
  done
done
[[ "$cases" -ge 9 ]] || bad "only $cases patchdirs fixtures ran"
run patchdirs; expect "no directory given = cannot run (zero inspected is a failure)" 2 "FAIL"
run patchdirs "$W/does-not-exist"; expect "nonexistent global patch dir = cannot run" 2 "FAIL"
# --out
mkdir -p "$W/o2" "$W/ext2/patches/linux/6.1.1"; echo x > "$W/ext2/patches/linux/0001-a.patch"
printf 'BR2_GLOBAL_PATCH_DIR="$(BR2_EXTERNAL_X_PATH)/patches"\n' > "$W/o2/.config"
printf 'export BR2_EXTERNAL_X_PATH = %s\n' "$W/ext2" > "$W/o2/.br2-external.mk"
run patchdirs --out "$W/o2"; expect "--out resolves BR2_GLOBAL_PATCH_DIR, finds the empty version dir" 1 "6.1.1 is empty"
rmdir "$W/ext2/patches/linux/6.1.1"
run patchdirs --out "$W/o2"; expect "--out, same tree after the empty dir is removed" 0 " 0 problem"
# the LIVE iHost global patch dirs (haos/ upstream patches are not part of this repo's tree)
run patchdirs "$ROOT/buildroot-ihost/patches-haos" "$ROOT/buildroot-external/patches" "$ROOT/buildroot-ihost/board/sonoff/ihost/patches"
expect "live iHost global patch dirs" 0 " 0 problem"
grep -q "^check-clean-bake patchdirs: 3 global patch dir(s)" <<<"$OUT" && ok "live iHost run inspected all 3 global patch dirs" || bad "live iHost run did not inspect 3 dirs :: $OUT"

echo
echo "gate selftest clean_bake: $ran checks, $fails failed"
[[ "$ran" -ge 30 ]] || { echo "FAIL: only $ran checks ran"; exit 1; }
[[ "$fails" -eq 0 ]]
