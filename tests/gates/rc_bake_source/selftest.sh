#!/usr/bin/env bash
# Self-test for the rc bake source (Odoo #1610): runs the LIVE bake-source-file.sh and the LIVE
# patched hassio.mk (scripts/apply-haos-patches.sh --cat), never a copy of either.
#   must-rc / must-stable: the rule table
#   make-level: an rc label bakes rc.json while /etc/ga-version-url and the updater channel still
#               name the STABLE line; a final bakes stable.json
# Zero cases is a failure.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RULE="$REPO/buildroot-external/package/hassio/bake-source-file.sh"
fails=0 n=0
ok()   { n=$((n+1)); }
bad()  { n=$((n+1)); fails=$((fails+1)); echo "FAIL $*"; }
[ -x "$RULE" ] || { echo "FAIL: $RULE missing or not executable (fail closed)"; exit 1; }

expect() { # release channel want
  local got; got=$("$RULE" "$1" "$2" 2>&1); [ "$got" = "$3" ] && ok || bad "rule($1,$2) = '$got', want '$3'"
}
expect BOSv1.6.0-rc3  stable rc
expect BOSv1.6.12-rc10 stable rc
expect BOSv1.6.0      stable stable      # final bakes the proven set
expect BOSv1.6.0-dev2 stable stable
expect BOSv1.6.0-dev2 dev    dev
expect BOSv1.6.0-rc3  dev    dev         # a dev-channel board never reads rc.json
expect BOSv1.6.0-rc3  beta   beta
expect BOSv1.5.3-rc1  stable stable      # the 1.5 line has no rc.json
expect BOSv1.6.0-rc3x stable stable
expect ""             stable stable      # developer make without GA_RELEASE
"$RULE" BOSv1.6.0-rc3 latest >/dev/null 2>&1 && bad "unknown channel accepted" || ok
"$RULE" onlyone >/dev/null 2>&1 && bad "wrong arg count accepted" || ok

# reachability (a rule nobody calls is dead): every consumer must call the one script
for f in tests/ga_tests/os_integrity/gen_expected.sh scripts/scan-cves.sh; do
  grep -q 'bake-source-file.sh' "$REPO/$f" && ok || bad "$f does not call bake-source-file.sh"
done
grep -q 'bake-source-file.sh' <("$REPO/scripts/apply-haos-patches.sh" --cat buildroot-external/package/hassio/hassio.mk) && ok || bad "patched hassio.mk does not call bake-source-file.sh"

# --- make level: the live patched hassio.mk -------------------------------------------------
mk=$(mktemp -d); trap 'rm -rf "$mk"' EXIT
"$REPO/scripts/apply-haos-patches.sh" --cat buildroot-external/package/hassio/hassio.mk > "$mk/hassio.mk" 2>"$mk/err" \
  || { echo "FAIL: cannot read the patched hassio.mk: $(head -3 "$mk/err")"; exit 1; }
# RC_TEST_MK_SED: red-proof hook only (mutates the extracted copy, never the tree)
[ -z "${RC_TEST_MK_SED:-}" ] || sed -i "$RC_TEST_MK_SED" "$mk/hassio.mk"
cat > "$mk/Makefile" <<MK
BR2_EXTERNAL_GA_HAOS_PATH := $REPO/buildroot-external
BR2_EXTERNAL_HAOS_PATH := $REPO/buildroot-external
BR2_PACKAGE_HASSIO_CHANNEL_STABLE := y
BR2_PACKAGE_HASSIO_MACHINE := "tinker"
TARGET_DIR := $mk/target
qstrip = \$(strip \$(subst ",,\$(1)))
define generic-package
endef
include $mk/hassio.mk
show:
	@echo "BAKE_URL=\$(HASSIO_VERSION_URL)\$(HASSIO_BAKE_FILE).json"
	@echo "DEVICE_URL=\$(HASSIO_VERSION_URL)\$(HASSIO_VERSION_CHANNEL).json"
	@mkdir -p $mk/target; \$(HASSIO_INSTALL_TARGET_CMDS); echo "ETC_GA_VERSION_URL=\$\$(cat $mk/target/etc/ga-version-url)"
MK
run() { GA_RELEASE="$1" make -s -f "$mk/Makefile" show 2>&1; }
STABLE_URL='https://raw.githubusercontent.com/greenautarky/haos-version/main/line/1.6/'
for rel in BOSv1.6.0-rc3 BOSv1.6.0; do
  out=$(run "$rel"); want=stable; [ "$rel" = BOSv1.6.0-rc3 ] && want=rc
  echo "$out" | grep -qE "^BAKE_URL=.*line/1\.6/.*$want\"?\.json" && ok || bad "$rel: bake url not $want: $out"
  echo "$out" | grep -qE "^DEVICE_URL=.*line/1.6/.*stable" && ok || bad "$rel: device url is not the stable line: $out"
  echo "$out" | grep -qxF "ETC_GA_VERSION_URL=$STABLE_URL" && ok || bad "$rel: /etc/ga-version-url is not the stable line URL: $out"
  [ "$want" = rc ] && { echo "$out" | grep -q 'BAKE_URL=.*stable' && bad "$rel: rc bake still reads stable"; }
done
[ "$n" -ge 15 ] || { echo "FAIL: only $n cases ran"; exit 1; }
echo "rc-bake-source self-test: $n case(s), $fails failure(s)"
[ "$fails" -eq 0 ]
