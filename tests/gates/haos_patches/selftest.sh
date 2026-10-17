#!/usr/bin/env bash
# Self-test for scripts/apply-haos-patches.sh (the LIVE script, never a copy).
#
# A throwaway git repo stands in for haos/; patches are generated against it.
# must-pass: a pending patch applies; a second run is idempotent; --check is
#            green on an applied set; --revert leaves the tree clean.
# must-fail: each case must fail with rc 1 AND name its own reason — a failure
#            for some other reason leaves the rule under test unproven:
#   broken patch   -> "neither applies nor is already applied"
#   stray edit     -> "carries changes no patch explains"
#   no patches     -> "no patches found"
#   no checkout    -> "is not initialised"
# Live: if the real haos/ submodule is checked out, the real patch set must
# apply to the pinned commit. CI checks it out for exactly this and sets
# HAOS_PATCHES_REQUIRE_LIVE=1, so a missing checkout there fails, never skips.
# Zero cases run = FAIL.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
gate="$repo/scripts/apply-haos-patches.sh"
[ -x "$gate" ] || { echo "FAIL: not executable: $gate"; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
bad=0 n=0 np=0

g() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
mkhaos() { # DIR — a fake upstream checkout with one file
	mkdir -p "$1/buildroot-external" && printf 'line1\nline2\nline3\n' > "$1/buildroot-external/a.sh"
	g "$1" init -q && g "$1" add -A && g "$1" commit -qm base
}
mkpatch() { # HAOS OUT — a patch that changes line2, generated then undone
	sed -i 's/^line2$/line2-ga/' "$1/buildroot-external/a.sh"
	g "$1" diff > "$2"
	g "$1" checkout -q -- .
}
run() { # HAOS PATCHDIR LAYERDIR ARGS... -> sets out rc
	out="$(HAOS_DIR="$1" GA_HAOS_PATCH_DIR_OVERRIDE="$2" GA_LAYER_PATCH_DIR_OVERRIDE="$3" "$gate" "${@:4}" 2>&1)"; rc=$?
}
pass_case() { # LABEL
	n=$((n+1)); np=$((np+1))
	if [ "$rc" -eq 0 ]; then echo "  ok    must-pass/$1"; else echo "  FAIL  must-pass/$1 rc=$rc :: $(tr '\n' '|' <<<"$out")"; bad=1; fi
}
fail_case() { # LABEL EXPECT
	n=$((n+1))
	if [ "$rc" -eq 1 ] && grep -qF -- "$2" <<<"$out"; then echo "  ok    must-fail/$1"
	else echo "  FAIL  must-fail/$1 rc=$rc want '$2' :: $(tr '\n' '|' <<<"$out")"; bad=1; fi
}

# --- must-pass ---------------------------------------------------------------
H="$tmp/haos"; P="$tmp/p"; L="$tmp/l"; mkdir -p "$P" "$L"; mkhaos "$H"; mkpatch "$H" "$P/0001-x.patch"
run "$H" "$P" "$L";            pass_case apply-pending
grep -qx 'line2-ga' "$H/buildroot-external/a.sh" || { echo "  FAIL  apply-pending did not change the file"; bad=1; }
run "$H" "$P" "$L";            pass_case second-run-idempotent
run "$H" "$P" "$L" --check;    pass_case check-applied
run "$H" "$P" "$L" --revert;   pass_case revert
[ -z "$(g "$H" status --porcelain)" ] || { echo "  FAIL  revert left changes in the tree"; bad=1; }

# --- must-fail ---------------------------------------------------------------
H2="$tmp/haos2"; mkhaos "$H2"; sed -i 's/^line2$/upstream-changed/' "$H2/buildroot-external/a.sh"; g "$H2" commit -qam bump
run "$H2" "$P" "$L";           fail_case broken-patch "neither applies nor is already applied"
H3="$tmp/haos3"; mkhaos "$H3"; echo stray >> "$H3/buildroot-external/a.sh"
mkdir -p "$tmp/p3"; printf 'other\n' > "$H3/b.sh"; g "$H3" add b.sh; g "$H3" commit -qm b
printf 'x\n' >> "$H3/b.sh"; g "$H3" diff -- b.sh > "$tmp/p3/0001-b.patch"; g "$H3" checkout -q -- b.sh
run "$H3" "$tmp/p3" "$L";      fail_case stray-edit "carries changes no patch explains"
mkdir -p "$tmp/empty"
run "$H" "$tmp/empty" "$tmp/empty"; fail_case no-patches "no patches found"
run "$tmp/not-a-checkout" "$P" "$L"; fail_case no-checkout "is not initialised"

# --- live: the real patch set applies to the pinned submodule ------------------
if [ -e "$repo/haos/.git" ]; then
	n=$((n+1)); np=$((np+1))
	out="$("$gate" 2>&1)"; rc=$?
	if [ "$rc" -eq 0 ]; then echo "  ok    live: real patch set applies to haos @ $(git -C "$repo/haos" rev-parse --short HEAD)"
	else echo "  FAIL  live patch set :: $out"; bad=1; fi
	"$gate" --revert >/dev/null 2>&1 || { echo "  FAIL  live revert"; bad=1; }
elif [ "${HAOS_PATCHES_REQUIRE_LIVE:-0}" = 1 ]; then
	echo "  FAIL  haos/ not checked out but HAOS_PATCHES_REQUIRE_LIVE=1"; bad=1
else
	echo "  note  haos/ not checked out: live patch-set case not run here (CI runs it)"
fi

[ "$n" -ge 8 ] && [ "$np" -ge 4 ] || { echo "FAIL: only $n cases ($np must-pass) ran"; exit 1; }
echo "$n cases ran"
exit "$bad"
