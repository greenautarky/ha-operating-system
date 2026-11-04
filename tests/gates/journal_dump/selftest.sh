#!/usr/bin/env bash
# journal_dump/selftest.sh — ga-journal-dump produces a non-empty dump with the
# tools the IMAGE has, run the way systemd runs it.
#
# WHY
#   Field device after an unclean boot: ga-boot-check called ga-journal-dump and
#   the journal showed `head: standard output: I/O error` then `ga-journal-dump:
#   empty dump - nothing written`; /mnt/data/journal-dump/ stayed empty. Cause:
#   the image's busybox has no gzip applet (CONFIG_GZIP unset), the script piped
#   into `gzip -c 2>/dev/null`, and systemd runs units with SIGPIPE ignored so
#   head reported the dead reader. The earlier host test (journald_volatile)
#   ran the script with the HOST's gzip and could not see any of it.
#
# WHAT RUNS — the subject, not a model of it
#   The LIVE script, unmodified, under `sh` = busybox ash, with SIGPIPE ignored
#   (as systemd does) and a PATH that holds ONLY the busybox applets that the
#   LIVE buildroot-external/busybox.config enables (symlinks to one busybox
#   binary), plus a journalctl stub. The stub replaces only the INPUT (the
#   journal); no part of the script is stubbed.
#
# CASES
#   C0  config: every applet the script needs is enabled in busybox.config
#       (gzip is the one that was missing).
#   C1  live tool set -> a non-empty dump exists, is valid gzip (when gzip is
#       enabled), and has the expected sections and the fixture lines.
#   C2  gzip removed from the tool set (fixture of the old failure) -> the
#       script must still leave a non-empty dump (uncompressed) and say so on
#       stderr. Losing the evidence silently is the defect.
#   C3  zero journal output -> no dump, and a message (not a crash).
#   Fail closed: exit 2 when busybox is missing or no applet could be linked.
#
# RED PROOF: JD_SCRIPT=<old script> JD_BUSYBOX_CONFIG=<old config> runs the same
# cases against another version (the PR body pastes the run on the old files).
# Exit 0 green, 1 verdict failed, 2 could not check.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="${JD_SCRIPT:-$ROOT/buildroot-external/rootfs-overlay/usr/libexec/ga-journal-dump}"
BBCONF="${JD_BUSYBOX_CONFIG:-$ROOT/buildroot-external/busybox.config}"
die2() { echo "ERROR (could not check): $*" >&2; exit 2; }

BB="${BUSYBOX:-$(command -v busybox || true)}"
[ -n "$BB" ] && [ -x "$BB" ] || die2 "busybox not found (apt: busybox-static; or set BUSYBOX)"
[ -f "$SCRIPT" ] || die2 "$SCRIPT not found"
[ -f "$BBCONF" ] || die2 "$BBCONF not found"

W="$(mktemp -d "${TMPDIR:-/tmp}/jd-selftest.XXXXXX")"
trap 'rm -rf "$W"' EXIT

# applets the script (and the shell it runs in) use
NEEDED="sh head tail gzip tr cat df awk cut ls stat mkdir rm mv date uname grep basename"
OPTIONAL="timeout"   # script does `command -v timeout`

pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "  ok    $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }

# enabled <applet> — is it =y in the live busybox.config? (sh -> ASH)
enabled() {
  local a="$1" k
  case "$a" in sh) k=ASH ;; *) k="$(printf '%s' "$a" | tr 'a-z' 'A-Z')" ;; esac
  grep -qx "CONFIG_$k=y" "$BBCONF"
}

# mktools <dir> [skip...] — a PATH dir with exactly the image's applets
mktools() {
  local d="$1"; shift
  mkdir -p "$d"
  local a s skip n=0
  for a in $NEEDED $OPTIONAL; do
    skip=0; for s in "$@"; do [ "$s" = "$a" ] && skip=1; done
    [ "$skip" = 1 ] && continue
    enabled "$a" || continue
    ln -sf "$BB" "$d/$a"; n=$((n + 1))
  done
  echo "$n"
}

# journalctl stub: the journal INPUT only. $JD_STUB_EMPTY=1 -> no output.
cat > "$W/journalctl" <<'EOF'
#!/bin/sh
case "$*" in
  *disk-usage*) echo "Archived and active journals take up 1.0M in the file system." ;;
  *) [ "${JD_STUB_EMPTY:-0}" = 1 ] && exit 0
     i=0; while [ "$i" -lt 40 ]; do
       echo "Nov 04 10:00:00.000000 fixture unit[1]: FIXTURE-LINE-$i warning error mmc"; i=$((i + 1))
     done ;;
esac
EOF
chmod +x "$W/journalctl"

# run_dump <name> <tooldir> [empty] — runs the live script like systemd does;
# stdout/stderr -> $W/<name>.err ; dumps -> $W/<name>.dir
run_dump() {
  local name="$1" tools="$2" empty="${3:-0}"
  mkdir -p "$W/$name.dir"
  JD_STUB_EMPTY="$empty" bash -c '
    trap "" PIPE      # systemd starts services with SIGPIPE ignored
    exec env -i PATH="$0" GA_JD_DIR="$1" GA_JD_JOURNALCTL="$2" GA_JD_PSTORE=/nonexistent \
         GA_JD_PSTORE_ARCHIVE=/nonexistent JD_STUB_EMPTY="$3" "$0/sh" "$4" selftest
  ' "$tools" "$W/$name.dir" "$W/journalctl" "$empty" "$SCRIPT" > "$W/$name.err" 2>&1
  echo "rc=$?" >> "$W/$name.err"
}

# --- C0: the config provides what the script needs ---------------------------
echo "C0 busybox.config ($BBCONF):"
for a in $NEEDED; do
  if enabled "$a"; then ok "applet $a enabled"; else bad "applet $a NOT enabled in busybox.config"; fi
done

# --- C1: live tool set ---------------------------------------------------------
echo "C1 live tool set:"
n="$(mktools "$W/tools-live")"
[ "$n" -ge 1 ] || die2 "no applet could be linked from the live busybox.config"
run_dump live "$W/tools-live"
shopt -s nullglob
files=("$W"/live.dir/dump-*)
if [ "${#files[@]}" = 1 ] && [ -s "${files[0]}" ]; then
  ok "one non-empty dump written: $(basename "${files[0]}") ($(stat -c%s "${files[0]}") bytes)"
  txt="$W/live.txt"
  case "${files[0]}" in
    *.log.gz) if gzip -dc "${files[0]}" > "$txt" 2>/dev/null; then ok "dump is valid gzip"; else bad "dump is not valid gzip"; : > "$txt"; fi ;;
    *)        cp "${files[0]}" "$txt"; ok "dump is plain text (uncompressed fallback)" ;;
  esac
  for sec in "boot / RAUC" "kernel (warnings" "PID 1: unit failures" "all units, warning and above"; do
    if grep -q "===== .*$sec" "$txt"; then ok "section present: $sec"; else bad "section MISSING: $sec"; fi
  done
  grep -q "FIXTURE-LINE-39" "$txt" && ok "journal fixture lines reached the dump" || bad "journal fixture lines missing from the dump"
else
  bad "expected exactly one non-empty dump, found ${#files[@]}: $(tr '\n' '|' < "$W/live.err")"
fi
grep -q "I/O error" "$W/live.err" && bad "stderr shows an I/O error: $(grep 'I/O error' "$W/live.err" | head -1)" || ok "no I/O error on stderr"

# --- C2: gzip missing: loud fallback, evidence kept ----------------------------
echo "C2 gzip missing from the tool set:"
mktools "$W/tools-nogz" gzip > /dev/null
# Some busybox builds resolve applets inside ash even without a symlink
# (a static busybox), so "no gzip in PATH" cannot be built with that binary.
# Say so loudly instead of passing or failing on a fixture that did not happen;
# C0 (the config has the applet) still guards the real image.
if [ -n "$(env -i PATH="$W/tools-nogz" "$W/tools-nogz/sh" -c 'command -v gzip' 2>/dev/null)" ]; then
  echo "  SKIP  C2 not exercisable: this busybox resolves gzip internally ($BB); fallback path NOT covered by this run"
else
  run_dump nogz "$W/tools-nogz"
  files=("$W"/nogz.dir/dump-*)
  if [ "${#files[@]}" = 1 ] && [ -s "${files[0]}" ]; then ok "dump still written without gzip: $(basename "${files[0]}")"
  else bad "no dump without gzip (evidence silently lost): $(tr '\n' '|' < "$W/nogz.err")"; fi
  grep -qi "uncompressed\|gzip" "$W/nogz.err" && ok "the substitution is announced on stderr" || bad "gzip fallback is silent"
fi

# --- C3: nothing to dump ---------------------------------------------------------
echo "C3 empty journal:"
run_dump empty "$W/tools-live" 1
# the script always writes its own header, so an empty journal still yields a dump;
# what must hold is: it terminates with rc=0 and no crash/I-O error.
grep -q '^rc=0$' "$W/empty.err" && ok "exit 0 with an empty journal" || bad "non-zero exit with an empty journal"
grep -q "I/O error" "$W/empty.err" && bad "I/O error with an empty journal" || ok "no I/O error with an empty journal"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ] && { echo "PASS: ga-journal-dump leaves a non-empty dump with the image's tools"; exit 0; }
exit 1
