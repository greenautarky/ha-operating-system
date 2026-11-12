#!/usr/bin/env bash
# =============================================================================
# selftest.sh — the RAUC bundle hook pins the running vccio5 mode (Odoo #1981)
# =============================================================================
# Option B (Thomas 2026-11-12): the iHost image boots vccio5 = 3.3 V when
# haos-config.txt has NO ga_vccio5 key. A field unit running 1.8 V must never
# meet that fallback, so the bundle's install-check hook pins the RUNNING mode
# (ga.vccio5= on /proc/cmdline, cross-checked against PMUGRF 0x140 bit 5) as an
# explicit key before any slot is written — or aborts the install.
#
# Drives the LIVE hook as the build ships it: upstream haos/ ota/rauc-hook with
# the whole GA patch set applied (scripts/apply-haos-patches.sh --cat). The hook
# runs as `sh hook install-check` against scratch files (GA_VCC_* paths), with a
# fake systemctl. Extraction finding no ga_vccio5_pin FAILS, never skips.
#   must-pass  no key + 3v3 running -> 3v3; no key + 1v8 / no argument -> 1v8;
#              key 1v8 / 3v3 present -> file untouched; missing file created;
#              CRLF and a missing trailing newline handled; other compatible ->
#              nothing written; compatible mismatch still exit 10 (upstream)
#   must-flag  cmdline vs PMUGRF mismatch (both ways); PMUGRF unreadable / no 0x140
#              line; unexpected ga.vccio5 value; read-only /mnt/boot — each with
#              rc >= 1 AND the file untouched
#   structure  the manifest declares install-check; the call sits in the
#              install-check branch (runs before every slot install, rauc v1.13)
#   mutations  of the LIVE hook: call removed, cross-check disabled, "always 1v8",
#              key-present check removed, compatible guard removed
# Needs: bash, sh, the haos/ submodule (CI: git submodule update --init haos),
# a non-root user (a read-only dir does not stop root).
# -----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
[[ $EUID -ne 0 ]] || { echo "FATAL: run as a normal user (root ignores the read-only case)"; exit 1; }
T="$(mktemp -d)"; trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
bash "$ROOT/scripts/apply-haos-patches.sh" --cat buildroot-external/ota/rauc-hook > "$T/hook" 2>"$T/cat.err" \
  || { echo "FATAL: cannot extract the patched rauc-hook: $(tail -2 "$T/cat.err")"; exit 1; }
grep -q 'ga_vccio5_pin()' "$T/hook" || { echo "FATAL: the patched rauc-hook has no ga_vccio5_pin — the gate would be blind"; exit 1; }
bash "$ROOT/scripts/apply-haos-patches.sh" --cat buildroot-external/ota/manifest.raucm.gtpl > "$T/manifest" 2>/dev/null \
  || { echo "FATAL: cannot extract the bundle manifest template"; exit 1; }

# fake systemctl (mnt-boot.mount "active") and grub-editenv: the iHost boots U-Boot,
# but a CI runner or a laptop may have grub-editenv, and upstream check_grubenv
# would then touch the real /mnt/boot before our hook — dependencies, not the subject.
mkdir -p "$T/bin"; printf '#!/bin/sh\nexit 0\n' > "$T/bin/systemctl"; cp "$T/bin/systemctl" "$T/bin/grub-editenv"
chmod +x "$T/bin/systemctl" "$T/bin/grub-editenv"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok    $*"; }
bad(){ fail=$((fail+1)); echo "  FAIL  $*"; }
REG_18="140: 000000a6"; REG_33="140: 00000086"

# run_hook <hook> <compat> <cfg-content|-ABSENT-> <cmdline> <regmap-content|-ABSENT-> [ro]
# -> sets RC, OUT, CFG (content after, "-ABSENT-" if none), BEFORE
run_hook() {
  local h="$1" compat="$2" cfg="$3" cmd="$4" reg="$5" ro="${6:-}" mvf="${7:-}" d pathx="$T/bin"
  d="$(mktemp -d -p "$T")"; mkdir "$d/boot"
  [[ "$cfg" == -ABSENT- ]] || printf '%b' "$cfg" > "$d/boot/haos-config.txt"
  printf '%s\n' "$cmd" > "$d/cmdline"
  [[ "$reg" == -ABSENT- ]] || printf '%s\n' "$reg" > "$d/regmap"
  BEFORE="$(cat "$d/boot/haos-config.txt" 2>/dev/null || echo -ABSENT-)"
  [[ -n "$ro" ]] && { chmod 444 "$d/boot/haos-config.txt" 2>/dev/null; chmod 555 "$d/boot"; }
  if [[ -n "$mvf" ]]; then   # a fake mv: "noop" claims success and moves nothing, "fail" fails
    mkdir -p "$d/mvbin"; pathx="$d/mvbin:$T/bin"
    if [[ "$mvf" == noop ]]; then printf '#!/bin/sh\nexit 0\n' > "$d/mvbin/mv"; else printf '#!/bin/sh\nexit 1\n' > "$d/mvbin/mv"; fi
    chmod +x "$d/mvbin/mv"
  fi
  OUT="$(PATH="$pathx:$PATH" RAUC_MF_COMPATIBLE="$compat" RAUC_SYSTEM_COMPATIBLE="$compat" \
         GA_VCC_BOOT="$d/boot" GA_VCC_CMDLINE="$d/cmdline" GA_VCC_REGMAP="$d/regmap" sh "$h" install-check 2>&1)"; RC=$?
  chmod -R u+w "$d" 2>/dev/null
  CFG="$(cat "$d/boot/haos-config.txt" 2>/dev/null || echo -ABSENT-)"
}
want_key() {  # <label> <expected key line> — rc 0 and the key appears exactly once
  if [[ $RC -eq 0 && "$(grep -cx "$2" <<<"$CFG")" == 1 && "$(grep -c '^ga_vccio5=' <<<"$CFG")" == 1 ]]; then ok "$1"
  else bad "$1 (rc=$RC, file: $(tr '\n' '|' <<<"$CFG"), out: ${OUT: -160})"; fi
}
want_refused() {  # <label> <text> — rc 11 (RAUC shows the reason only for >= 10), file untouched,
                  # and the reason is the LAST stderr line (the one RAUC reports)
  if [[ $RC -eq 11 && "$CFG" == "$BEFORE" && "$(tail -n 1 <<<"$OUT")" == *"$2"* ]]; then ok "$1"
  else bad "$1 (rc=$RC, untouched=$([[ "$CFG" == "$BEFORE" ]] && echo yes || echo NO), out: ${OUT: -200})"; fi
}
want_untouched() {  # <label> — rc 0, file byte-identical
  if [[ $RC -eq 0 && "$CFG" == "$BEFORE" ]]; then ok "$1"; else bad "$1 (rc=$RC, before: $(tr '\n' '|' <<<"$BEFORE"), after: $(tr '\n' '|' <<<"$CFG"))"; fi
}

cases() {  # <hook> — every expectation on one hook; returns 0 when all hold (for mutations)
  local h="$1" f0=$fail
  run_hook "$h" haos-ihost ""                "root=x ga.vccio5=3v3 rootwait" "$REG_33"; want_key "no key + running 3v3 -> ga_vccio5=3v3 pinned" "ga_vccio5=3v3"
  run_hook "$h" haos-ihost ""                "root=x ga.vccio5=1v8 rootwait" "$REG_18"; want_key "no key + running 1v8 -> ga_vccio5=1v8 pinned" "ga_vccio5=1v8"
  run_hook "$h" haos-ihost "overlays=x\n"    "root=x rootwait"               "$REG_18"; want_key "no key + no ga.vccio5 (pre-#1900 boot.scr) -> 1v8" "ga_vccio5=1v8"
  run_hook "$h" haos-ihost "ga_vccio5=1v8\n" "root=x ga.vccio5=3v3"          "$REG_33"; want_untouched "key 1v8 present -> untouched"
  run_hook "$h" haos-ihost "ga_vccio5=3v3\n" "root=x ga.vccio5=3v3"          "$REG_33"; want_untouched "key 3v3 on a unit running 3.3 V -> untouched"
  run_hook "$h" haos-ihost "ga_vccio5=3v3\n" "root=x rootwait"               "$REG_18"; want_refused "key 3v3 on a unit running 1.8 V -> refused (the OTA would move it to 3.3 V)" "would move it to 3.3 V"
  run_hook "$h" haos-ihost "ga_vccio5=1v8\nga_vccio5=\n" "root=x rootwait"   "$REG_18"; want_key "last value empty (boot.scr: no key) -> pinned, one key line left" "ga_vccio5=1v8"
  [[ "$CFG" == "ga_vccio5=1v8" ]] && ok "last value empty -> exactly one key line in the file" || bad "last value empty -> file: $(tr '\n' '|' <<<"$CFG")"
  run_hook "$h" haos-ihost "ga_vccio5=\nga_vccio5=1v8\n" "root=x ga.vccio5=3v3" "$REG_33"; want_untouched "last value 1v8 (earlier empty line) -> key present, untouched"
  run_hook "$h" haos-ihost "#ga_vccio5=3v3\nxga_vccio5=3v3\n" "root=x rootwait" "$REG_18"; want_key "commented / prefixed key is no key -> running 1v8 pinned" "ga_vccio5=1v8"
  run_hook "$h" haos-ihost "overlays=x\n"    "root=x rootwait"               "$REG_18" "" noop; want_refused "mv claims success but moves nothing -> read-back refuses" "did not read back"
  run_hook "$h" haos-ihost "overlays=x\n"    "root=x rootwait"               "$REG_18" "" fail; want_refused "mv fails -> refused with its own reason" "cannot replace"
  run_hook "$h" haos-ihost "ga_vccio5=\n"    "root=x rootwait"               "$REG_18"; want_key "empty ga_vccio5= is no key (boot.scr: 3v3) -> running 1v8 pinned" "ga_vccio5=1v8"
  run_hook "$h" haos-ihost ""                "root=x ga.vccio5=3v3"          "$REG_18"; want_refused "mismatch: cmdline 3v3 vs PMUGRF 1.8 V -> refused" "says 1v8"
  run_hook "$h" haos-ihost ""                "root=x rootwait"               "$REG_33"; want_refused "mismatch: no argument (1v8) vs PMUGRF 3.3 V -> refused" "says 3v3"
  run_hook "$h" haos-ihost ""                "root=x rootwait"               -ABSENT-;  want_refused "PMUGRF unreadable -> refused, nothing written" "cannot read PMUGRF"
  run_hook "$h" haos-ihost ""                "root=x rootwait"               "144: 0000ffff"; want_refused "PMUGRF without a 0x140 line -> refused" "no PMUGRF 0x140 line"
  run_hook "$h" haos-ihost ""                "root=x ga.vccio5=foo"          "$REG_18"; want_refused "unexpected ga.vccio5 value -> refused" "unexpected ga.vccio5=foo"
  run_hook "$h" haos-ihost "overlays=x\n"    "root=x rootwait"               "$REG_18" ro; want_refused "read-only /mnt/boot -> refused (install aborted)" "install refused"
  run_hook "$h" haos-ihost -ABSENT-          "root=x rootwait"               "$REG_18"; want_key "missing haos-config.txt -> created with the key" "ga_vccio5=1v8"
  run_hook "$h" haos-ihost "overlays=x\r\nfoo=1\r\n" "root=x rootwait"       "$REG_18"; want_key "CRLF file -> other lines kept, key added" "ga_vccio5=1v8"
  [[ "$CFG" == $'overlays=x\nfoo=1\nga_vccio5=1v8' ]] && ok "CRLF file -> exact content" || bad "CRLF file content: $(tr '\n' '|' <<<"$CFG")"
  run_hook "$h" haos-ihost "foo=1"           "root=x rootwait"               "$REG_18"
  [[ $RC -eq 0 && "$CFG" == $'foo=1\nga_vccio5=1v8' ]] && ok "last line without newline is not glued to the key" || bad "no trailing newline: rc=$RC content: $(tr '\n' '|' <<<"$CFG")"
  run_hook "$h" haos-dsgw210 ""              "root=x rootwait"               -ABSENT-;  want_untouched "other compatible (dsgw210) -> nothing written, no PMUGRF read"
  # upstream behaviour kept: a foreign bundle is still rejected with 10
  RC=0; OUT="$(PATH="$T/bin:$PATH" RAUC_MF_COMPATIBLE=haos-ova RAUC_SYSTEM_COMPATIBLE=haos-ihost sh "$h" install-check 2>&1)" || RC=$?
  [[ $RC -eq 10 ]] && ok "compatible mismatch still rejected with exit 10 (upstream)" || bad "compatible mismatch rc=$RC"
  [[ $fail -eq $f0 ]]
}

echo "== live patched hook (apply-haos-patches.sh --cat)"
cases "$T/hook"

echo "== structure"
grep -qE '^hooks=install-check;?$' "$T/manifest" && ok "bundle manifest declares the install-check hook" || bad "manifest has no hooks=install-check"
awk '/^ *install-check\)/{f=1} f&&/;;/{exit} f&&/ga_vccio5_pin \|\| exit 11/{print "y"; exit}' "$T/hook" | grep -q y \
  && ok "ga_vccio5_pin is called in the install-check branch (before every slot install)" || bad "ga_vccio5_pin is not called in install-check"

echo "== mutations of the live hook (each must turn the cases red)"
mut() {  # <label> <python-replace-from> <to>
  python3 - "$T/hook" "$T/m.hook" "$2" "$3" <<'PY' || { bad "mutation $1: pattern not found (dead mutation)"; return; }
import sys; s=open(sys.argv[1]).read(); a,b=sys.argv[3],sys.argv[4]
if s.count(a)<1: sys.exit(1)
open(sys.argv[2],"w").write(s.replace(a,b,1))
PY
  local fsave=$fail pmut=$pass
  cases "$T/m.hook" >/dev/null 2>&1; local r=$?
  fail=$fsave; pass=$pmut
  [[ $r -ne 0 ]] && ok "mutation $1: caught" || bad "mutation $1 was NOT caught"
}
mut call-removed        'ga_vccio5_pin || exit 11' 'true || exit 11'
mut silent-exit-code    'ga_vccio5_pin || exit 11' 'ga_vccio5_pin || exit 1'
mut crosscheck-off      'if [ "${_gv_reg}" != "${_gv_run}" ]; then' 'if false; then'
mut always-1v8          '        3v3) ;;' '        3v3) _gv_run=1v8 ;;'
mut key-check-removed   '        ""|3v3) ;;' '        *) ;;'
mut empty-counts-as-key '        ""|3v3) ;;' '        3v3) ;;'
mut last-line-not-used  "sed -n 's/^ga_vccio5=//p' | tail -n 1)" "sed -n 's/^ga_vccio5=//p' | head -n 1)"
mut anchor-removed      "sed -n 's/^ga_vccio5=//p' | tail -n 1)" "sed -n 's/.*ga_vccio5=//p' | tail -n 1)"
mut readback-off        '| grep -cx "ga_vccio5=${_gv_run}")" != 1 ]; then' '| grep -cx "ga_vccio5=${_gv_run}")" = 99 ]; then'
mut mv-guard-off        'mv -f "${_gv_tmp}" "${_gv_cfg}" || {' 'mv -f "${_gv_tmp}" "${_gv_cfg}" || true || {'
mut 3v3-key-on-1v8-off  '        if [ "${_gv_run}" = 1v8 ]; then' '        if false; then'
mut compat-guard-off    '[ "${RAUC_SYSTEM_COMPATIBLE}" = "haos-ihost" ] || return 0' ':'

echo "vccio5_rauc_hook: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
