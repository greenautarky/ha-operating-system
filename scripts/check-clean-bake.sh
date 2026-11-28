#!/usr/bin/env bash
# check-clean-bake.sh -- a reused output tree (update/partial/kernel bake) must not
# ship inputs that were generated from an OLDER source than the one in the tree.
#
#   check-clean-bake.sh bootscr   --out OUT [--require]  (source + boot.scr resolved from OUT; --require: a missing boot.scr is a finding)
#   check-clean-bake.sh bootscr   --boot-scr F --source F
#   check-clean-bake.sh patchdirs --out OUT            (BR2_GLOBAL_PATCH_DIR resolved from OUT)
#   check-clean-bake.sh patchdirs DIR [DIR...]         (DIR = a global patch dir)
#
# exit 0 = clean, 1 = a finding (stale / harmful), 2 = the check could not run.
# A check that cannot run is a failure, never a skip (exit 2 is fatal in ga_build.sh).
#
# WHY
#   bootscr   Buildroot generates boot.scr (mkimage over uboot-boot.ush) in the
#             BUILD step of host-uboot-tools and copies it to images/. A reused tree
#             does not rebuild host-uboot-tools when only the .ush changed, so images/
#             kept a boot.scr from before the VCCIO5 change and every bake shipped it
#             (found by hand, 2026-11-26). mkimage stores the script verbatim after a
#             64-byte header and an 8-byte size table, so freshness is a byte compare
#             of the embedded text with the source -- not a timestamp guess.
#   patchdirs Buildroot picks <patchdir>/<pkg>/<version> INSTEAD of <patchdir>/<pkg>
#             as soon as that directory exists (pkg-utils.mk pkg-patches-dirs:
#             $(or $(wildcard dir/VERSION),dir)). A version directory that carries no
#             patch -- empty, or only a .hash file -- therefore silently drops every
#             patch of the parent directory. Flagged: a version directory without a
#             patch file (anything not *.hash), when it is empty, or when the parent
#             directory carries patches that it would shadow.
set -uo pipefail

die() { echo "check-clean-bake: FAIL: $*" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || die "python3 missing"

# cfg_value OUT KEY -> value of KEY from OUT/.config with $(BR2_EXTERNAL_<N>_PATH) expanded
# from OUT/.br2-external.mk. Unexpanded references left over are an error (exit 2).
cfg_value() {
  python3 -I - "$1" "$2" <<'PY'
import re, sys
out, key = sys.argv[1], sys.argv[2]
try:
    cfg = open(out + "/.config").read()
    ext = open(out + "/.br2-external.mk").read()
except OSError as e:
    sys.exit("cannot read %s" % e.filename)
paths = dict(re.findall(r"^export (BR2_EXTERNAL_[A-Z0-9_]+_PATH) = (.*)$", ext, re.M))
m = re.search(r'^%s="(.*)"$' % re.escape(key), cfg, re.M)
if not m:
    sys.exit("%s not set in %s/.config" % (key, out))
v = re.sub(r"\$\((BR2_EXTERNAL_[A-Z0-9_]+_PATH)\)", lambda x: paths.get(x.group(1), x.group(0)), m.group(1))
if "$(" in v:
    sys.exit("unresolved reference in %s: %s" % (key, v))
print(v)
PY
}

embedded_script() {   # BOOT_SCR -> script text on stdout; exit 3 when not a mkimage script
  python3 -I - "$1" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
if len(d) < 72 or struct.unpack(">I", d[:4])[0] != 0x27051956:
    sys.exit(3)
dsize = struct.unpack(">I", d[12:16])[0]
if d[30] != 6:                       # ih_type 6 = IH_TYPE_SCRIPT
    sys.exit(3)
n = struct.unpack(">I", d[64:68])[0]
if n + 8 > dsize or 72 + n > len(d):
    sys.exit(3)
sys.stdout.buffer.write(d[72:72 + n])
PY
}

cmd_bootscr() {
  local out="" scr="" src="" require=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) out="$2"; shift 2 ;;
      --boot-scr) scr="$2"; shift 2 ;;
      --source) src="$2"; shift 2 ;;
      --require) require=1; shift ;;
      *) die "bootscr: unknown argument $1" ;;
    esac
  done
  if [[ -n "$out" ]]; then
    [[ -n "$scr" ]] || scr="$out/images/boot.scr"
    if [[ -z "$src" ]]; then
      local enabled
      enabled="$(sed -n 's/^BR2_PACKAGE_HOST_UBOOT_TOOLS_BOOT_SCRIPT=\(.*\)$/\1/p' "$out/.config" 2>/dev/null)"
      if [[ "$enabled" != "y" ]]; then echo "check-clean-bake bootscr: this board generates no boot.scr (BR2_PACKAGE_HOST_UBOOT_TOOLS_BOOT_SCRIPT not set) -- nothing to compare"; return 0; fi
      src="$(cfg_value "$out" BR2_PACKAGE_HOST_UBOOT_TOOLS_BOOT_SCRIPT_SOURCE)" || die "cannot resolve the boot script source: $src"
    fi
  fi
  [[ -n "$scr" && -n "$src" ]] || die "bootscr: need --out or --boot-scr and --source"
  [[ -s "$src" ]] || die "boot script source '$src' missing or empty"
  if [[ ! -e "$scr" ]]; then
    [[ $require -eq 0 ]] || { echo "check-clean-bake bootscr: BAD  $scr does not exist after the build" >&2; return 1; }
    echo "check-clean-bake bootscr: no $scr yet (first build) -- nothing stale to compare"; return 0
  fi
  local got want
  # status read from the command itself, not from a substitution
  embedded_script "$scr" >/dev/null 2>&1 ||  { echo "check-clean-bake bootscr: BAD  $scr is not a readable mkimage script image" >&2; return 1; }
  got="$(embedded_script "$scr"; echo x)"; got="${got%x}"
  want="$(cat "$src"; echo x)"; want="${want%x}"
  if [[ "$got" == "$want" ]]; then
    echo "check-clean-bake bootscr: OK   $scr embeds the current $(basename "$src") (${#want} bytes)"
    return 0
  fi
  echo "check-clean-bake bootscr: BAD  $scr was generated from an OLDER $(basename "$src") (embedded ${#got} bytes, source ${#want} bytes); rebuild host-uboot-tools" >&2
  return 1
}

# patchdirs DIR... : prints one BAD line per finding
scan_patchdirs() {
  python3 -I - "$@" <<'PY'
import os, sys
dirs = sys.argv[1:]
bad = 0; looked = 0
def has_patch(d):
    return any(os.path.isfile(os.path.join(d, f)) and not f.endswith(".hash") for f in os.listdir(d))
for g in dirs:
    if not os.path.isdir(g):
        print("check-clean-bake patchdirs: FAIL global patch dir %s does not exist" % g, file=sys.stderr); sys.exit(2)
    for pkg in sorted(os.listdir(g)):
        p = os.path.join(g, pkg)
        if not os.path.isdir(p): continue
        for v in sorted(os.listdir(p)):
            vd = os.path.join(p, v)
            if not (os.path.isdir(vd) and v[:1].isdigit()): continue
            looked += 1
            entries = os.listdir(vd)
            if not entries:
                print("check-clean-bake patchdirs: BAD  %s is empty: Buildroot uses it instead of %s and skips every patch there" % (vd, p)); bad += 1
            elif not has_patch(vd) and has_patch(p):
                print("check-clean-bake patchdirs: BAD  %s holds no patch (only %s): Buildroot uses it instead of %s and drops that directory's patches" % (vd, ",".join(sorted(entries)), p)); bad += 1
print("check-clean-bake patchdirs: %d global patch dir(s), %d version dir(s) inspected, %d problem(s)" % (len(dirs), looked, bad))
sys.exit(1 if bad else 0)
PY
}

cmd_patchdirs() {
  local dirs=()
  if [[ "${1:-}" == "--out" ]]; then
    local v; v="$(cfg_value "$2" BR2_GLOBAL_PATCH_DIR)" || die "cannot resolve BR2_GLOBAL_PATCH_DIR: $v"
    read -r -a dirs <<<"$v"
  else
    dirs=("$@")
  fi
  [[ ${#dirs[@]} -gt 0 ]] || die "patchdirs: no global patch dir given/resolved (zero dirs inspected is a failure)"
  scan_patchdirs "${dirs[@]}"
}

sub="${1:-}"; shift || true
case "$sub" in
  bootscr) cmd_bootscr "$@" ;;
  patchdirs) cmd_patchdirs "$@" ;;
  *) die "usage: $0 bootscr|patchdirs ..." ;;
esac
