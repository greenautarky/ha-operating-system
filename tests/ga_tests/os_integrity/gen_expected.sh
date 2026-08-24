#!/usr/bin/env bash
# gen_expected.sh — bake the DECLARED state into expected.env, repo-side.
#
# WHY THIS FILE EXISTS
# ====================
# On 2026-08-20 the flashed rc3 image carried OpenSSL 3.4.4 while master
# declared 3.5.7 (#369, merged the day before): the bake moved the buildroot
# submodule POINTER but never updated the submodule, and the only thing that
# said so was a human running `openssl version` on the device. The same day,
# four add-on pipelines were found building from a base their build.yaml did
# not declare. One class: DECLARATION AND ARTEFACT, COMPARED BY NOBODY.
#
# The os_integrity suite is that comparison, on the device. This generator is
# its declaration side: every expectation here is read from the repo's pinned
# declarations — version.yaml, the defconfig, the buildroot submodule pointer,
# addon-images.json — and NEVER from the artefact under test (N2: an audit
# must not derive its expected value from the thing it audits).
#
# Run this on the LAPTOP/CI before shipping tests to a device. It fails closed:
# an expectation it cannot derive is an error, never a blank — a blank would
# make the device test skip, and "could not check" must never read as green.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$(dirname "$0")/expected.env"
cd "$REPO_ROOT"

fail() { echo "gen_expected: ERROR: $*" >&2; exit 1; }

# --- gaos_release + core, from version.yaml -------------------------------
REL=$(awk '/^gaos_release:/{print $2; exit}' version.yaml)
[ -n "$REL" ] || fail "no gaos_release in version.yaml"
CORE=$(awk -F'"' '/^  homeassistant_core:/{print $2; exit}' version.yaml)
[ -n "$CORE" ] || fail "no homeassistant_core pin in version.yaml"

# --- kernel, from the live defconfig --------------------------------------
KERNEL=$(sed -nE 's/^BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="([0-9.]+)"/\1/p' buildroot-ihost/configs/ga_ihost_full_defconfig | head -1)
[ -n "$KERNEL" ] || fail "no kernel version in ga_ihost_full_defconfig"

# --- openssl, from the PINNED buildroot submodule -------------------------
# Two sources, in order of preference:
#   1. an initialised submodule checkout — but ONLY if it sits exactly on the
#      pinned commit ('+'/'-' prefix in `git submodule status` means it does
#      not, and reading a drifted checkout would repeat the rc3 defect here);
#   2. the pinned commit fetched straight from the fork on GitHub.
# No third fallback. If neither works, this fails.
BR_SHA=$(git ls-tree HEAD buildroot | awk '{print $3}')
[ -n "$BR_SHA" ] || fail "no buildroot submodule pointer on HEAD"
OPENSSL=""
if [ -f buildroot/package/libopenssl/libopenssl.mk ] \
   && git submodule status buildroot 2>/dev/null | grep -q "^ ${BR_SHA}"; then
  OPENSSL=$(grep -E '^LIBOPENSSL_VERSION = ' buildroot/package/libopenssl/libopenssl.mk | awk '{print $3}')
else
  OPENSSL=$(curl -fsS "https://raw.githubusercontent.com/home-assistant/buildroot/${BR_SHA}/package/libopenssl/libopenssl.mk" \
              | grep -E '^LIBOPENSSL_VERSION = ' | awk '{print $3}') || true
fi
[ -n "$OPENSSL" ] || fail "could not derive OpenSSL from buildroot @ ${BR_SHA} (submodule drifted or unreachable) — refusing to emit a blank expectation"

# --- add-on images, from the bake pin file --------------------------------
ADDONS=$(python3 - <<'PY'
import json
d = json.load(open("buildroot-external/package/hassio/addon-images.json"))["addons"]
out = []
for slug, e in sorted(d.items()):
    out.append(f"{slug}={e['image'].replace('{arch}','armv7')}:{e['version']}")
print(" ".join(out))
PY
)
[ -n "$ADDONS" ] || fail "no addons in addon-images.json"
N_ADDONS=$(echo "$ADDONS" | wc -w)
[ "$N_ADDONS" -ge 6 ] || fail "only ${N_ADDONS} addons derived — coverage too low to be plausible"

# --- the version plane the SUPERVISOR reads -------------------------------
# Plugins and Core are NOT pinned in this repo — the Supervisor resolves them
# from greenautarky/haos-version {channel}.json (ADR-0018 §2). This is the one
# expectation group whose source is that JSON. Fetched REPO-SIDE for the channel
# the caller names — never read from the device, which is the artefact under test.
#   CHANNEL=beta sh gen_expected.sh   → expectations for a beta canary
CHANNEL="${CHANNEL:-stable}"
PLUGINS=$(CHANNEL="$CHANNEL" python3 - <<'PYEOF'
import json, os, sys, urllib.request
url = ("https://raw.githubusercontent.com/greenautarky/haos-version/main/"
       + os.environ["CHANNEL"] + ".json")
try:
    d = json.loads(urllib.request.urlopen(url, timeout=20).read())
except Exception as e:
    sys.exit("could not fetch " + url + ": " + str(e))
imgs = d.get("images", {})
out = []
for slug in ("dns", "cli", "audio", "observer", "multicast"):
    v, tmpl = d.get(slug), imgs.get(slug)
    if not v or not tmpl:
        sys.exit("channel json missing version or image template for " + slug)
    out.append(slug + "=" + tmpl.replace("{arch}", "armv7") + ":" + v)
print(" ".join(out))
PYEOF
) || fail "could not derive plugin expectations for channel $CHANNEL"
N_PLUGINS=$(echo "$PLUGINS" | wc -w)
[ "$N_PLUGINS" -eq 5 ] || fail "expected 5 plugins from the channel json, got ${N_PLUGINS}"

cat > "$OUT" <<EOF
# GENERATED by gen_expected.sh from the repo's declarations — do not edit.
# source commit: $(git rev-parse --short HEAD)  generated: pinned values only, no timestamps
EXPECTED_GA_RELEASE="$REL"
EXPECTED_KERNEL="$KERNEL"
EXPECTED_OPENSSL="$OPENSSL"
EXPECTED_CORE="$CORE"
EXPECTED_ADDON_IMAGES="$ADDONS"
EXPECTED_CHANNEL="$CHANNEL"
EXPECTED_PLUGINS="$PLUGINS"
EOF
echo "expected.env written:"
sed 's/^/  /' "$OUT"
