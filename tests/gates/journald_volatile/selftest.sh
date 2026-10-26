#!/usr/bin/env bash
# journald_volatile/selftest.sh - the journal is RAM-only AND the failure trail
# that replaces `journalctl -b -1` is wired to all three triggers and bounded.
#
# WHY
#   Journald was 57 % of all SD-card writes on an idle bench device (Odoo #1256,
#   option C). Storage=volatile removes them; the price is that a reboot erases
#   the evidence of why it happened. ga-journal-dump keeps a small bounded trail
#   on the data partition. Each half rots silently on its own: the config can be
#   flipped back to persistent (writes return, nobody sees a failure), and a
#   trigger can be dropped or moved (the trail silently stops being written).
#
# WHAT IT CHECKS (check_tree, run over fixtures AND the live tree)
#   STORAGE      journald.conf: the effective (last) Storage= is volatile
#   RUNTIMEMAX   RuntimeMaxUse is set and <= 128M (the journal lives in RAM)
#   SCRIPT       usr/libexec/ga-journal-dump exists and is executable
#   BOUND        MAX_BYTES <= 2 MiB and the output is cut by head -c "$MAX_BYTES"
#   KEEP         KEEP in 1..10 and rotation compares against it
#   UNIT_STOP    the shutdown unit runs the script as ExecStop, ordered After the
#                data mount (so ExecStop runs while it is still mounted)
#   UNIT_ENABLED the unit is linked into sysinit.target.wants
#   HOOK_RAUC    ga-rauc-install calls the script BEFORE `rauc install`
#   HOOK_BOOT    ga-boot-check calls the script
#   FB_PATH      no fluent-bit config pins a systemd input to /var/log/journal
#                (a runtime-only journal lives in /run/log/journal)
#
# BEHAVIOUR (live script, fake journalctl, dash)
#   - output stays <= the bound although the fake journal is ~10x larger,
#     each priority class (boot/RAUC, kernel, PID 1, warnings) is present
#   - 8 dumps leave exactly KEEP files, same boot+reason replaces itself
#   - RED: a mutant with the caps/guard removed breaches the bound
#
# Fixtures: must-fail/<name>/ trees each break exactly one check and must be
# flagged with exactly that tag; must-pass/<name>/ must be clean.
# The component fluent-bit-tier0.conf (ga-telemetry-config at the version.yaml
# pin) is fetched like the cursor-sync gate does; TIER0_OVERLAY_CONF=<file>
# overrides offline.
#
# Exit 0 = green, 1 = a verdict failed, 2 = could not check (never green).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HERE="$ROOT/tests/gates/journald_volatile"
OVL="$ROOT/buildroot-external/rootfs-overlay"
# Overlay order of the iHost image (ga_ihost_full_defconfig BR2_ROOTFS_OVERLAY):
# the board overlay comes after the GA one, so its journald drop-ins win.
IHOST_OVL="$ROOT/buildroot-ihost/rootfs-overlay"
. "$ROOT/scripts/lib/journald-effective.sh" || { echo "ERROR (could not check): journald-effective.sh missing" >&2; exit 2; }
die2() { echo "ERROR (could not check): $*" >&2; exit 2; }
pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "  ok    $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }

W="$(mktemp -d "${TMPDIR:-/tmp}/jd-gate.XXXXXX")"
trap 'rm -rf "$W"' EXIT

# size_mb <value like 64M|1G|512K> -> MB (integer, rounded up); empty on garbage
size_mb() {
  case "$1" in
    *[Gg]) echo $(( ${1%[Gg]} * 1024 )) ;;
    *[Mm]) echo "${1%[Mm]}" ;;
    *[Kk]) echo 1 ;;
    *[!0-9]*|"") echo "" ;;
    *) echo $(( $1 / 1048576 + 1 )) ;;
  esac
}

# check_tree <overlay-root>[:<overlay-root>...] <fluent-conf>... -> one TAG per failed check
# STORAGE/RUNTIMEMAX read the EFFECTIVE journald value over all roots (main file
# + drop-ins in journald's order); the other checks read the first root.
check_tree() {
  local roots="$1"; shift
  local o="${roots%%:*}"; local -a rl; IFS=: read -r -a rl <<<"$roots"
  local jc="$o/etc/systemd/journald.conf" sc="$o/usr/libexec/ga-journal-dump"
  local unit="$o/usr/lib/systemd/system/ga-journal-dump-shutdown.service"
  local st rm n max keep l_h l_r

  st="$(jd_effective Storage "${rl[@]}" | tr 'A-Z' 'a-z')"
  [ "$st" = volatile ] || echo STORAGE
  rm="$(jd_effective RuntimeMaxUse "${rl[@]}")"
  n="$(size_mb "$rm")"
  { [ -n "$n" ] && [ "$n" -le 128 ]; } || echo RUNTIMEMAX

  if [ ! -x "$sc" ]; then echo SCRIPT; echo BOUND; echo KEEP
  else
    max="$(sed -n 's/^MAX_BYTES=\([0-9]*\)$/\1/p' "$sc" | head -1)"
    { [ -n "$max" ] && [ "$max" -le 2097152 ] && grep -qE '^[^#]*head -c "\$MAX_BYTES"' "$sc"; } || echo BOUND
    keep="$(sed -n 's/^KEEP=\([0-9]*\)$/\1/p' "$sc" | head -1)"
    { [ -n "$keep" ] && [ "$keep" -ge 1 ] && [ "$keep" -le 10 ] && grep -qE '^[^#]*-gt "\$KEEP"' "$sc"; } || echo KEEP
  fi

  { grep -qE '^ExecStop=.*ga-journal-dump' "$unit" 2>/dev/null \
    && grep -E '^After=' "$unit" | grep -q 'mnt-data.mount'; } || echo UNIT_STOP
  [ -L "$o/etc/systemd/system/sysinit.target.wants/ga-journal-dump-shutdown.service" ] || echo UNIT_ENABLED

  l_h="$(grep -nE '^[^#]*ga-journal-dump|^[^#]*JOURNAL_DUMP_BIN" ' "$o/usr/sbin/ga-rauc-install" 2>/dev/null | head -1 | cut -d: -f1)"
  l_r="$(grep -nE '^[^#]*rauc install "' "$o/usr/sbin/ga-rauc-install" 2>/dev/null | head -1 | cut -d: -f1)"
  { [ -n "$l_h" ] && [ -n "$l_r" ] && [ "$l_h" -lt "$l_r" ]; } || echo HOOK_RAUC
  grep -qE '^[^#]*ga-journal-dump' "$o/usr/libexec/ga-boot-check" 2>/dev/null || echo HOOK_BOOT

  if [ "$#" -gt 0 ] && grep -hE '^[[:space:]]*Path[[:space:]]+.*/var/log/journal' "$@" 2>/dev/null | grep -q .; then echo FB_PATH; fi
}

# --- fixtures --------------------------------------------------------------
echo "fixtures:"
nf=0 np=0
for d in "$HERE"/must-fail/*/; do
  [ -d "$d" ] || continue; nf=$((nf + 1)); name="$(basename "$d")"
  want="$(cat "$d/EXPECT" 2>/dev/null)"
  [ -n "$want" ] || die2 "must-fail/$name has no EXPECT file"
  got="$(check_tree "$d/overlay" "$d"/fluent/*.conf | sort | tr '\n' ' ' | sed 's/ $//')"
  if [ "$got" = "$want" ]; then ok "must-fail $name flagged exactly: $got"
  else bad "must-fail $name: expected '$want', got '${got:-nothing}'"; fi
done
for d in "$HERE"/must-pass/*/; do
  [ -d "$d" ] || continue; np=$((np + 1)); name="$(basename "$d")"
  got="$(check_tree "$d/overlay" "$d"/fluent/*.conf | tr '\n' ' ')"
  if [ -z "$got" ]; then ok "must-pass $name clean"; else bad "must-pass $name flagged: $got"; fi
done
[ "$nf" -ge 6 ] && [ "$np" -ge 1 ] || die2 "fixture dirs incomplete (must-fail=$nf must-pass=$np)"

# --- live tree -------------------------------------------------------------
echo "live:"
TC_VER="$(sed -n 's/^[[:space:]]*ga-telemetry-config:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/version.yaml")"
[ -n "$TC_VER" ] || die2 "no ga-telemetry-config pin in version.yaml"
if [ -n "${TIER0_OVERLAY_CONF:-}" ]; then
  cp "$TIER0_OVERLAY_CONF" "$W/fluent-bit-tier0.conf" || die2 "cannot read $TIER0_OVERLAY_CONF"
else
  curl -fsS --retry 3 --max-time 30 -o "$W/fluent-bit-tier0.conf" \
    "https://raw.githubusercontent.com/greenautarky/ga-telemetry-config/v${TC_VER}/src/ga-telemetry-config/etc/fluent-bit/fluent-bit-tier0.conf" \
    || die2 "cannot fetch fluent-bit-tier0.conf at v$TC_VER"
fi
mapfile -t fb < <(find "$ROOT"/buildroot-*/rootfs-overlay/etc/fluent-bit "$ROOT/buildroot-external/package/fluent-bit-config" -name '*.conf' -type f 2>/dev/null | sort)
fb+=("$W/fluent-bit-tier0.conf")
nsys="$(cat "${fb[@]}" | grep -ciE '^[[:space:]]*Name[[:space:]]+systemd[[:space:]]*$')"
[ "$nsys" -ge 3 ] || die2 "the live scan saw only $nsys systemd inputs - layout changed"
[ -d "$IHOST_OVL" ] || die2 "no iHost board overlay at $IHOST_OVL - layout changed"
live="$(check_tree "$OVL:$IHOST_OVL" "${fb[@]}" | tr '\n' ' ')"
if [ -z "$live" ]; then ok "live tree clean ($nsys systemd inputs scanned)"; else bad "live tree fails: $live"; fi

# --- behaviour: the real script over a fake, oversized journal -------------
echo "behaviour:"
SC="$OVL/usr/libexec/ga-journal-dump"
[ -x "$SC" ] || die2 "no $SC"
FAKE="$W/journalctl"
cat > "$FAKE" <<'FEOF'
#!/bin/sh
# fake journalctl: ~3 MB per call, system marker at the END (the dump keeps the newest lines)
case "$*" in *--disk-usage*) echo "Archived and active journals take 1.0M in the file system."; exit 0 ;; esac
tag=WARN; fill="filler warning line"
case " $* " in
  *" -k "*) tag=KERN; fill="kernel: mmc0: I/O error filler" ;;
  *" -u "*) tag=BOOT ;;
  *_PID=1*) tag=PID1 ;;
esac
i=0
while [ $i -lt 40000 ]; do echo "Jan 01 00:00:00 host x: $fill $i xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; i=$((i+1)); done
echo "Jan 01 00:00:00 host x: MARK-$tag error fatal"
FEOF
chmod +x "$FAKE"

run_dump() { # run_dump <script> <dir> <boot> <reason> <ts>
  GA_JD_DIR="$2" GA_JD_JOURNALCTL="$FAKE" GA_JD_PSTORE="$W/nopstore" GA_JD_BOOT_ID="$3" GA_JD_TS="$5" \
    GA_JD_MIN_FREE_KB=1 sh "$1" "$4" >/dev/null 2>&1
}
D1="$W/d1"
run_dump "$SC" "$D1" aaaaaaaa-0000 shutdown 20260101T000001
f="$(ls "$D1"/dump-*.log.gz 2>/dev/null | head -1)"
[ -n "$f" ] || { bad "no dump written by the live script"; f=/dev/null; }
size="$(zcat "$f" 2>/dev/null | wc -c)"
fake_total=$(( 3 * 4 * 1024 * 1024 ))
if [ "$size" -gt 0 ] && [ "$size" -le 2097152 ]; then ok "dump $size bytes <= 2097152 (input was ~$((fake_total/1048576)) MB)"
else bad "dump size $size outside (0, 2097152]"; fi
for m in MARK-BOOT MARK-KERN MARK-PID1 MARK-WARN; do
  if [ "$(zcat "$f" 2>/dev/null | grep -c "$m")" -ge 1 ]; then ok "priority class present: $m"; else bad "priority class missing: $m"; fi
done
for i in 1 2 3 4 5 6 7 8; do run_dump "$SC" "$D1" "bbbb000$i" shutdown "2026010${i}T000000"; done
run_dump "$SC" "$D1" bbbb0008 shutdown 20260109T000000   # same boot+reason: replaces
cnt="$(ls "$D1"/dump-*.log.gz | wc -l)"
keep="$(sed -n 's/^KEEP=\([0-9]*\)$/\1/p' "$SC" | head -1)"
if [ "$cnt" = "$keep" ]; then ok "rotation: $cnt files after 10 runs (KEEP=$keep)"; else bad "rotation: $cnt files, expected $keep"; fi
same="$(ls "$D1"/dump-*-bbbb0008-shutdown.log.gz | wc -l)"
[ "$same" = 1 ] && ok "same boot+reason replaces its earlier dump" || bad "same boot+reason left $same files"
newest="$(ls -1 "$D1"/dump-*.log.gz | tail -1)"
case "$newest" in *20260109T000000*) ok "newest dump survives rotation" ;; *) bad "newest dump missing after rotation: $newest" ;; esac

# RED: remove the per-section caps and the global guard -> the bound must break
MUT="$W/ga-journal-dump.mutant"
sed -e 's/tail -c "\$2"/cat/' -e 's/head -c "\$MAX_BYTES"/cat/' "$SC" > "$MUT"
cmp -s "$SC" "$MUT" && die2 "mutant is identical to the live script - the sed no longer matches the caps"
D2="$W/d2"
run_dump "$MUT" "$D2" cccccccc-0000 shutdown 20260101T000001
msize="$(zcat "$D2"/dump-*.log.gz 2>/dev/null | wc -c)"
if [ "$msize" -gt 2097152 ]; then ok "RED mutant (caps removed) breaches the bound: $msize bytes"
else bad "RED mutant did not breach the bound ($msize bytes) - the size check cannot fail"; fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ] && { echo "PASS: journal is RAM-only, failure trail wired to shutdown / rauc install / boot check and bounded"; exit 0; }
exit 1
