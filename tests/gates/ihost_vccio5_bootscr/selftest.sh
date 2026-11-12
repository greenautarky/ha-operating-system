#!/usr/bin/env bash
# =============================================================================
# selftest.sh — the iHost boot script picks the vccio5 DTB safely (Odoo #1900)
# =============================================================================
# The block in uboot-boot.ush that loads rv11xx-sonoff-ihost-vccio5-3v3.dtb for
# ga_vccio5=3v3 is the riskiest code of #1900: if `setenv fdtfile ${fdtfile_3v3}`
# ever runs for a file that is not on the boot partition, `fatload` fails and the
# device does not boot. This gate EXTRACTS the LIVE block (from
# `setenv ga_vccio5_loaded 1v8` to the `setenv bootargs_ga "ga.vccio5=...`
# line) and runs it through a tiny evaluator for exactly the statements it uses
# (if/else/fi, test "x${A}" = "xB", test -e mmc <dev>:<part> <file>, setenv,
# echo). Any other statement fails closed. Cases, every one on the LIVE block:
#   must-pass  3v3 + variant on the partition -> fdtfile = variant, loaded 3v3
#              3v3 + variant MISSING          -> fdtfile unchanged, loaded 1v8
#              no key / other value            -> fdtfile unchanged, loaded 1v8
#              rv1109 SoC                      -> the rv1109 variant
#              bootargs_ga starts with ga.vccio5=<loaded> and keeps the old args
# must-flag cases are mutations of the LIVE block: the `test -e` guard removed
# (`if true`), the guard testing another name, the key compare loosened, and the
# variant set outside the guard. The extraction FAILS if it finds no block.
# What it cannot prove: U-Boot's real hush parsing (the bench boot did, #1047).
# -----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
USH="${USH:-$ROOT/buildroot-ihost/board/sonoff/ihost/uboot-boot.ush}"
[[ -s "$USH" ]] || { echo "FATAL: $USH missing"; exit 1; }
command -v python3 >/dev/null || { echo "FATAL: python3 required"; exit 1; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fails=0; n=0
bad() { n=$((n + 1)); fails=$((fails + 1)); echo "  FAIL  $*"; }
ok()  { n=$((n + 1)); echo "  ok    $*"; }

cat > "$W/ev.py" <<'PY'
import re, sys, json
# argv: script ga_vccio5 cpucode files(comma) -> prints JSON {fdtfile, loaded, bootargs_ga}
path, key, cpu, files = sys.argv[1], sys.argv[2], sys.argv[3], set(filter(None, sys.argv[4].split(",")))
lines = open(path).read().splitlines()
try:
    a = next(i for i, l in enumerate(lines) if l.strip() == "setenv ga_vccio5_loaded 1v8")
    b = next(i for i in range(a, len(lines)) if lines[i].strip().startswith('setenv bootargs_ga "ga.vccio5='))
except StopIteration:
    sys.exit(3)                                   # extraction found nothing: the gate would be blind
env = {"ga_vccio5": key, "cpucode#": cpu, "devnum": "1", "boot_partnum": "1",
       "fdtfile": f"rv{cpu}-sonoff-ihost.dtb", "bootargs_ga": "usbcore.authorized_default=0 g_serial.iSerialNumber=0123"}
def exp(t): return re.sub(r"\$\{([^}]+)\}", lambda m: env.get(m.group(1), ""), t)
def cond(c):
    c = c.strip()
    if c == "true": return True
    if c == "false": return False
    m = re.fullmatch(r'test "([^"]*)" = "([^"]*)"', c)
    if m: return exp(m.group(1)) == exp(m.group(2))
    m = re.fullmatch(r'test -e mmc (\S+) (\S+)', c)
    if m: return exp(m.group(2)) in files
    raise SystemExit(f"unsupported condition: {c}")
stack = []                                         # entries: [taken_now, any_taken]
def live(): return all(s[0] for s in stack)
for raw in lines[a:b + 1]:
    t = raw.strip()
    if not t or t.startswith("#"): continue
    m = re.fullmatch(r"if (.*); then", t)
    if m:
        v = cond(m.group(1)) if live() else False
        stack.append([v, v]); continue
    if t == "else":
        s = stack[-1]; s[0] = not s[1]; continue
    if t == "fi": stack.pop(); continue
    if not live(): continue
    m = re.fullmatch(r'setenv (\S+) "(.*)"', t) or re.fullmatch(r"setenv (\S+) (\S+)", t)
    if m: env[m.group(1)] = exp(m.group(2)); continue
    if t.startswith("echo "): continue
    raise SystemExit(f"unsupported statement: {t}")
if stack: raise SystemExit("unbalanced if/fi")
print(json.dumps({"fdtfile": env["fdtfile"], "loaded": env.get("ga_vccio5_loaded", ""), "bootargs_ga": env["bootargs_ga"]}))
PY
ev() { python3 "$W/ev.py" "$@"; }
V26=rv1126-sonoff-ihost-vccio5-3v3.dtb; V09=rv1109-sonoff-ihost-vccio5-3v3.dtb
B26=rv1126-sonoff-ihost.dtb; B09=rv1109-sonoff-ihost.dtb

# verdict <script> -> 0 when every must-pass expectation holds on it
verdict() {
  local f="$1" r good=1
  r=$(ev "$f" 3v3 1126 "$B26,$V26") || return 2
  [[ $r == *"\"fdtfile\": \"$V26\""* && $r == *'"loaded": "3v3"'* ]] || good=0
  [[ $r == *'"bootargs_ga": "ga.vccio5=3v3 usbcore.authorized_default=0 g_serial.iSerialNumber=0123"'* ]] || good=0
  r=$(ev "$f" 3v3 1126 "$B26") || return 2
  [[ $r == *"\"fdtfile\": \"$B26\""* && $r == *'"loaded": "1v8"'* && $r == *'"bootargs_ga": "ga.vccio5=1v8 '* ]] || good=0
  r=$(ev "$f" "" 1126 "$B26,$V26") || return 2                # option B: no key -> 3v3
  [[ $r == *"\"fdtfile\": \"$V26\""* && $r == *'"loaded": "3v3"'* ]] || good=0
  r=$(ev "$f" "" 1126 "$B26") || return 2                     # no key, variant missing -> 1v8 fallback
  [[ $r == *"\"fdtfile\": \"$B26\""* && $r == *'"loaded": "1v8"'* ]] || good=0
  r=$(ev "$f" 1v8 1126 "$B26,$V26") || return 2               # explicit 1v8 wins over an available variant
  [[ $r == *"\"fdtfile\": \"$B26\""* && $r == *'"loaded": "1v8"'* ]] || good=0
  r=$(ev "$f" "3v3 " 1126 "$B26,$V26") || return 2           # not exactly 3v3/1v8/empty -> 1.8 V
  [[ $r == *"\"fdtfile\": \"$B26\""* && $r == *'"loaded": "1v8"'* ]] || good=0
  r=$(ev "$f" foo 1126 "$B26,$V26") || return 2
  [[ $r == *"\"fdtfile\": \"$B26\""* && $r == *'"loaded": "1v8"'* ]] || good=0
  r=$(ev "$f" 3v3 1109 "$B09,$V09") || return 2
  [[ $r == *"\"fdtfile\": \"$V09\""* && $r == *'"loaded": "3v3"'* ]] || good=0
  r=$(ev "$f" 3v3 1109 "$B09,$V26") || return 2               # only the OTHER SoC's variant present
  [[ $r == *"\"fdtfile\": \"$B09\""* && $r == *'"loaded": "1v8"'* ]] || good=0
  [[ $good == 1 ]]
}

verdict "$USH"; rc=$?
case $rc in
  0) ok "live block: no key -> 3v3 (variant) / 1v8 (no variant); 3v3 -> variant; explicit 1v8 and any other value -> 1v8; rv1109; bootargs_ga prefix" ;;
  2) bad "live block: extraction/evaluation failed (gate would be blind): $(ev "$USH" 3v3 1126 x 2>&1 | tail -1)" ;;
  *) bad "live block: an expectation does not hold" ;;
esac

mut() {  # <label> <sed-expr>
  local f="$W/m-$1"; sed "$2" "$USH" > "$f"
  cmp -s "$f" "$USH" && { bad "mutation $1: sed did not change the script (mutation is dead)"; return; }
  verdict "$f"; local r=$?
  [[ $r != 0 ]] && ok "mutation $1: flagged, as it must be" || bad "mutation $1 was NOT flagged"
}
mut guard-removed      's/^\(\s*\)if test -e mmc ${devnum}:${boot_partnum} ${fdtfile_3v3}; then$/\1if true; then/'
mut guard-wrong-file   's/^\(\s*\)if test -e mmc ${devnum}:${boot_partnum} ${fdtfile_3v3}; then$/\1if test -e mmc ${devnum}:${boot_partnum} ${fdtfile}; then/'
# Odoo #1981 (option B): each rule of the key selection, attacked on its own
mut no-key-not-3v3     's/^    if test "x${ga_vccio5}" = "x"; then$/    if false; then/'
mut 3v3-key-ignored    's/^  if test "x${ga_vccio5}" = "x3v3"; then$/  if false; then/'
mut garbage-to-3v3     's/^setenv ga_vccio5_want 1v8$/setenv ga_vccio5_want 3v3/'
mut want-compare-loose 's/^if test "x${ga_vccio5_want}" = "x3v3"; then$/if true; then/'
mut no-fallback-reset  's/^setenv ga_vccio5_loaded 1v8$/setenv ga_vccio5_loaded 3v3/'
mut arg-appended       's/^setenv bootargs_ga "ga.vccio5=${ga_vccio5_loaded} ${bootargs_ga}"$/setenv bootargs_ga "${bootargs_ga} ga.vccio5=${ga_vccio5_loaded}"/'
# the variant set OUTSIDE the guard (moved up, before the test -e)
awk '/^  if test -e mmc \$\{devnum\}:\$\{boot_partnum\} \$\{fdtfile_3v3\}; then$/ {print "  setenv fdtfile ${fdtfile_3v3}"} {print}' "$USH" > "$W/m-outside"
verdict "$W/m-outside"; [[ $? != 0 ]] && ok "mutation set-outside-guard: flagged, as it must be" || bad "mutation set-outside-guard was NOT flagged"
# no block at all -> the extraction must FAIL, not pass
grep -v '^setenv ga_vccio5_loaded 1v8$' "$USH" > "$W/m-noblock"
verdict "$W/m-noblock"; [[ $? == 2 ]] && ok "no block in the script: extraction FAILS (never a silent pass)" || bad "a script without the block was not reported as unextractable"

echo "ihost_vccio5_bootscr: $((n - fails))/$n ok"
[[ $fails == 0 ]]
