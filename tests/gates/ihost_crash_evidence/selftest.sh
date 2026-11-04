#!/usr/bin/env bash
# ihost_crash_evidence/selftest.sh - the iHost keeps evidence of WHY it reset.
#
# WHY
#   A field iHost hard-resets ~1.4x/day and the logs just stop. Power loss, a
#   hang that the DW watchdog resets, and a panic (PANIC_TIMEOUT=5 -> silent
#   reboot) all look identical unless the kernel log survives a warm reset.
#   Each mechanism rots silently: ramoops without a DT region registers
#   nothing, PSTORE_RAM=m loads too late, a detector set to "warn" instead of
#   "panic" leaves the hang as an empty-pstore watchdog reset.
#
# WHAT IT CHECKS (check_tree, over fixtures AND the live tree)
#   KCFG:<sym>     the iHost kernel fragment sets the symbol as pinned below
#                  (last assignment wins, as merge_config does)
#   RAMOOPS_NODE   the DT patch adds a ramoops node: compatible, reg, no-map,
#                  console-size > 0, record-size > 0, not disabled
#   RAMOOPS_ADDR   the region lies in [0x0a600000, 0x10000000) and clears the
#                  boot chain: DTB 0x08300000, OP-TEE 0x08400000..0x0a600000
#   RESET_REASON   ga-boot-check logs CRU_GLB_RST_ST (0x...0404 off CRU
#                  0xff490000), PMIC ON/OFF source and pstore record count on
#                  the unclean branch, and the logged line carries them
#   ORDER          (live tree only) the board fragment is the LAST kernel
#                  fragment in the defconfig, so nothing overrides it
#   MMIO_READ      the reset register is read with `devmem` (mmap), never
#                  dd/read() on /dev/mem (EFAULT for MMIO on ARM)
#   ADDR_ARITH     no $(( )) on the address (the target shell is 32-bit
#                  signed: $((0xff490404)) = -11992060)
#   DEVMEM_APPLET  busybox-ga.fragment builds the devmem applet
#   DTB            (only with GA_IHOST_DTB=<file>) the COMPILED DTB has an
#                  enabled ramoops node; needs dtc
# BEHAVIOUR (live ga-boot-check functions, fake devmem and PMIC regmap; run
# under the host sh and, with GA_TARGET_ROOT=<built target tree>, under the
# target's 32-bit sh via qemu-arm)
#   - raw CRU word, decode (wdt / power-on / unreadable), PMIC raw bytes and
#     pstore count appear in the logged line
#
# Fixtures: must-fail/<name>/ breaks exactly one check and must be flagged with
# exactly that tag; must-pass/<name>/ must be clean. A fixture holds any of
# kernel.config, ramoops.patch, ga-boot-check; a missing file is the live one.
#
# Exit 0 = green, 1 = a verdict failed, 2 = could not check (never green).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HERE="$ROOT/tests/gates/ihost_crash_evidence"
LIVE_CFG="$ROOT/buildroot-ihost/board/sonoff/ihost/kernel.config"
LIVE_PATCH="$ROOT/buildroot-ihost/board/sonoff/ihost/patches/linux/0006-ihost-ramoops.patch"
LIVE_BC="$ROOT/buildroot-external/rootfs-overlay/usr/libexec/ga-boot-check"
DEFCONFIG="$ROOT/buildroot-ihost/configs/ga_ihost_full_defconfig"

die2() { echo "ERROR (could not check): $*" >&2; exit 2; }
pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "  ok    $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }

# Pinned expectations (NOT derived from the artifact under test).
PINNED_CFG="CONFIG_PSTORE=y CONFIG_PSTORE_CONSOLE=y CONFIG_PSTORE_RAM=y
CONFIG_DEBUG_KERNEL=y CONFIG_SOFTLOCKUP_DETECTOR=y CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC=y
CONFIG_HARDLOCKUP_DETECTOR=y CONFIG_BOOTPARAM_HARDLOCKUP_PANIC=y
CONFIG_DETECT_HUNG_TASK=y CONFIG_BOOTPARAM_HUNG_TASK_PANIC=y
CONFIG_DEFAULT_HUNG_TASK_TIMEOUT=300"

cfg_value() {  # <file> <CONFIG_X> -> last assignment ("n" when unset/absent)
  local v
  v=$(grep -E "^(# )?$2[= ]" "$1" | tail -n 1)
  case "$v" in
    "$2="*) echo "${v#*=}" ;;
    *) echo n ;;
  esac
}

# prints the failing tags, one per line, for the tree in $1 (fixture dir or "")
check_tree() {
  local d="$1" cfg patch bc kv sym want got frag
  cfg="$LIVE_CFG";   [ -n "$d" ] && [ -f "$d/kernel.config" ] && cfg="$d/kernel.config"
  patch="$LIVE_PATCH"; [ -n "$d" ] && [ -f "$d/ramoops.patch" ] && patch="$d/ramoops.patch"
  bc="$LIVE_BC";     [ -n "$d" ] && [ -f "$d/ga-boot-check" ] && bc="$d/ga-boot-check"
  [ -r "$cfg" ] || { echo "NOFILE:kernel.config"; return; }

  for kv in $PINNED_CFG; do
    sym=${kv%%=*}; want=${kv#*=}
    got=$(cfg_value "$cfg" "$sym")
    [ "$got" = "$want" ] || echo "KCFG:$sym"
  done

  # ramoops node, from the lines the patch ADDS
  local node reg addr size
  if [ -r "$patch" ]; then
    node=$(sed -n 's/^+//p' "$patch" | sed -n '/ramoops@/,/^[[:space:]]*};/p')
  else
    node=""
  fi
  if [ -z "$node" ] \
     || ! grep -q 'compatible = "ramoops"' <<<"$node" \
     || ! grep -qw 'no-map' <<<"$node" \
     || grep -q 'status = "disabled"' <<<"$node" \
     || ! grep -Eq 'console-size = <0x0*[1-9a-fA-F][0-9a-fA-F]*>' <<<"$node" \
     || ! grep -Eq 'record-size = <0x0*[1-9a-fA-F][0-9a-fA-F]*>' <<<"$node"; then
    echo "RAMOOPS_NODE"
  fi
  reg=$(sed -n 's/.*reg = <\(0x[0-9a-fA-F]*\) \(0x[0-9a-fA-F]*\)>;.*/\1 \2/p' <<<"$node" | head -n 1)
  addr=${reg%% *}; size=${reg##* }
  if [ -z "$reg" ] || [ $((addr)) -lt $((0x0a600000)) ] || [ $((addr + size)) -gt $((0x10000000)) ]; then
    echo "RAMOOPS_ADDR"
  fi

  # The reader must use mmap (devmem), never read() on /dev/mem (EFAULT for
  # MMIO on ARM), and never do shell arithmetic on the 32-bit-negative address.
  local code
  code=$(grep -v '^[[:space:]]*#' "$bc")
  if ! grep -Eq '"\$DEVMEM_BIN" "\$CRU_RST_ST_ADDR" 32' <<<"$code" || grep -Eq 'dd if=|/dev/mem' <<<"$code"; then
    echo "MMIO_READ"
  fi
  if grep -Eq '\$\(\( *[^)]*(CRU_RST_ST_ADDR|\boff\b|0x[89a-fA-F][0-9a-fA-F]{7})' <<<"$code"; then
    echo "ADDR_ARITH"
  fi
  frag="$ROOT/buildroot-external/busybox-ga.fragment"; [ -n "$d" ] && [ -f "$d/busybox-ga.fragment" ] && frag="$d/busybox-ga.fragment"
  grep -qx 'CONFIG_DEVMEM=y' "$frag" 2>/dev/null || echo "DEVMEM_APPLET"

  # unclean branch logs the reset reason
  if ! grep -q 'cru_glb_rst_st=' "$bc" || ! grep -q 'pmic_on_source=' "$bc" \
     || ! grep -q 'pstore_records=' "$bc" || ! grep -q '^CRU_RST_ST_ADDR=0xff490404$' "$bc" \
     || ! awk '/^main\(\)/{m=1} m&&/log_reset_reason/{f=1} END{exit !f}' "$bc"; then
    echo "RESET_REASON"
  fi
}

expect_clean() {  # <label> <dir>
  local out; out=$(check_tree "$2")
  if [ -z "$out" ]; then ok "$1"; else bad "$1 flagged: $(echo $out)"; fi
}
expect_flag() {   # <label> <dir> <tag>
  local out; out=$(check_tree "$2")
  if [ "$(echo "$out")" = "$3" ]; then ok "$1 -> $3"; else bad "$1 expected exactly '$3', got '$(echo $out)'"; fi
}

[ -r "$LIVE_CFG" ] || die2 "$LIVE_CFG missing"
[ -r "$LIVE_BC" ]  || die2 "$LIVE_BC missing"

echo "== live tree"
live=$(check_tree "")
if [ -z "$live" ]; then ok "live tree: all checks hold"; else bad "live tree flagged: $(echo $live)"; fi

# ORDER: the board fragment must be the last fragment in the defconfig list
frags=$(sed -n 's/^BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES="\(.*\)"/\1/p' "$DEFCONFIG")
[ -n "$frags" ] || die2 "no BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES in $DEFCONFIG"
lastfrag=${frags##* }
case "$lastfrag" in
  *board/sonoff/ihost/kernel.config) ok "ORDER: board fragment is last" ;;
  *) bad "ORDER: last fragment is '$lastfrag', not board/sonoff/ihost/kernel.config" ;;
esac

echo "== must-pass fixtures"
n=0
for d in "$HERE"/must-pass/*/; do
  [ -d "$d" ] || continue; n=$((n + 1))
  expect_clean "must-pass/$(basename "$d")" "$d"
done
[ "$n" -gt 0 ] || die2 "no must-pass fixtures (fail closed)"

echo "== must-fail fixtures"
n=0
for d in "$HERE"/must-fail/*/; do
  [ -d "$d" ] || continue; n=$((n + 1))
  tag=$(cat "$d/EXPECT" 2>/dev/null) || die2 "$d has no EXPECT"
  expect_flag "must-fail/$(basename "$d")" "$d" "$tag"
done
[ "$n" -gt 0 ] || die2 "no must-fail fixtures (fail closed)"

echo "== behaviour: live ga-boot-check reset-reason functions"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
awk '/^CRU_RST_ST_ADDR=/{p=1} /^main\(\)/{p=0} p' "$LIVE_BC" > "$T/fn.sh"
[ -s "$T/fn.sh" ] || die2 "could not extract reset-reason functions from ga-boot-check (fail, never skip)"
# The reader is exercised through a fake `devmem` FUNCTION that records its
# arguments, so the test also proves the address reaches devmem as the literal
# string (no shell arithmetic on it) and in 32-bit access mode.
run_case() {  # <runner...> -- <devmem-output-or-empty> <regs-file> <npstore> -> logged line
  local -a runner=()
  while [ "$1" != "--" ]; do runner+=("$1"); shift; done; shift
  local word="$1" regs="$2" np="$3"
  rm -rf "$T/ps"; mkdir "$T/ps"; local i=0; while [ "$i" -lt "$np" ]; do : > "$T/ps/rec$i"; i=$((i + 1)); done
  rm -f "$T/args"
  cat > "$T/case.sh" <<EOS
CRASH_LOG="$T/crash.log"; : > "\$CRASH_LOG"
GA_PMIC_REGS="$regs"; GA_PSTORE_DIR="$T/ps"; GA_DEVMEM_BIN=fake_devmem
fake_devmem() { echo "\$*" >> "$T/args"; [ -n "$word" ] || return 1; echo "$word"; }
. "$T/fn.sh"
log_reset_reason
EOS
  "${runner[@]}" "$T/case.sh" 2>&1
}
printf 'f4: 00\nf5: 40\nf6: 00\nf7: 00\n' > "$T/regs"
behave() {  # <label> <runner...>
  local label="$1"; shift
  local out
  out=$(run_case "$@" -- 0x00000010 "$T/regs" 2)
  case "$out" in *"cru_glb_rst_st=0x00000010 (first-wdt)"*"pmic_on_source=40"*"pmic_off_source=00"*"pstore_records=2"*) ok "$label: wdt reset decoded, PMIC raw + pstore count logged" ;; *) bad "$label: wdt case: $out" ;; esac
  [ "$(cat "$T/args" 2>/dev/null)" = "0xff490404 32" ] && ok "$label: devmem called with the literal string '0xff490404 32'" || bad "$label: devmem args were '$(cat "$T/args" 2>/dev/null)'"
  out=$(run_case "$@" -- 0x0 "$T/regs" 0)
  case "$out" in *"cru_glb_rst_st=0x00000000 (power-on)"*"pstore_records=0"*) ok "$label: zero word decoded as power-on, pstore 0" ;; *) bad "$label: power-on case: $out" ;; esac
  out=$(run_case "$@" -- 0xFF490404 "$T/regs" 0)
  case "$out" in *"cru_glb_rst_st=0xFF490404 (first-tsadc-thermal)"*) ok "$label: a word with the top bit set is not mangled (no signed arithmetic)" ;; *) bad "$label: high-bit case: $out" ;; esac
  out=$(run_case "$@" -- "" "$T/nonexistent" 0)
  case "$out" in *"cru_glb_rst_st=unreadable"*"pmic_on_source=unreadable"*) ok "$label: unreadable sources are logged as unreadable (loud, not silent)" ;; *) bad "$label: unreadable case: $out" ;; esac
}
behave "host sh" sh
# 32-bit semantics: the TARGET's own shell under qemu-user (set GA_TARGET_ROOT to
# a built target tree). Measured there: $((0xff490404)) = -11992060.
if [ -n "${GA_TARGET_ROOT:-}" ]; then
  command -v qemu-arm >/dev/null || die2 "GA_TARGET_ROOT set but no qemu-arm"
  [ -x "$GA_TARGET_ROOT/bin/sh" ] || die2 "no $GA_TARGET_ROOT/bin/sh"
  [ "$(qemu-arm -L "$GA_TARGET_ROOT" "$GA_TARGET_ROOT/bin/sh" -c 'echo $((0xff490404))')" -lt 0 ] \
    || die2 "target sh arithmetic is not 32-bit signed any more: this gate's premise changed"
  behave "target sh (qemu-arm)" qemu-arm -L "$GA_TARGET_ROOT" "$GA_TARGET_ROOT/bin/sh"
fi

if [ -n "${GA_IHOST_DTB:-}" ]; then
  echo "== compiled DTB: $GA_IHOST_DTB"
  command -v dtc >/dev/null || [ -x "${GA_DTC:-}" ] || die2 "GA_IHOST_DTB set but no dtc"
  dts=$(${GA_DTC:-dtc} -I dtb -O dts "$GA_IHOST_DTB" 2>/dev/null) || die2 "cannot decompile $GA_IHOST_DTB"
  blk=$(sed -n '/ramoops@/,/};/p' <<<"$dts")
  if grep -q 'compatible = "ramoops"' <<<"$blk" && grep -q 'reg = <0xb000000 0x100000>' <<<"$blk" \
     && ! grep -q 'status = "disabled"' <<<"$blk"; then
    ok "DTB: enabled ramoops node at the pinned address"
  else
    bad "DTB: no enabled ramoops node at 0x0b000000 in the compiled DTB"
  fi
fi

echo
echo "ihost_crash_evidence: $pass ok, $fail failed"
[ "$((pass + fail))" -gt 0 ] || die2 "nothing was checked"
[ "$fail" -eq 0 ]
