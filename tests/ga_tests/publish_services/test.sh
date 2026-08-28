#!/bin/sh
# ga-publish-services — the host->addon bridge for the GA services address.
#
# WHY THIS EXISTS. `GA_SERVICES_IP` lives in /etc/ga-services.conf (baked) and
# may be overridden at /mnt/data/ga-services.conf. Both are HOST paths, and an
# add-on container maps neither: it sees /share, /ssl, /homeassistant, /data and
# its own config dir. So an add-on opening either path gets ENOENT every time
# and cannot tell that apart from "the key is not set".
#
# Measured on a bench device on 2026-08-28: the address was present on the host
# and invisible from inside ga_manager, which is why the reverse-proxy trust
# block it was wanted for resolved to the loopback alone.
#
# Pure host-side: needs only sh + coreutils/busybox. No device required.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "ga-publish-services (services address -> /share)"

OVERLAY="$SCRIPT_DIR/../../../buildroot-external/rootfs-overlay"
PUB="/usr/libexec/ga-publish-services"
[ -x "$PUB" ] || PUB="$OVERLAY/usr/libexec/ga-publish-services"
SHARE_PUB="/usr/libexec/ga-share-publish"
[ -x "$SHARE_PUB" ] || SHARE_PUB="$OVERLAY/usr/libexec/ga-share-publish"

run_test "GPS-01" "helper present + executable" "test -x '$PUB'"

WORK="$(mktemp -d 2>/dev/null || echo /tmp/gps_$$)"
SHARE="$WORK/share"; STAGE="$WORK/stage"
mkdir -p "$SHARE" "$STAGE"
TARGET="$SHARE/ga-services.json"

# Publish with every path pointed at the sandbox. GA_SHARE_STAGE_DIR must be on
# the same filesystem as the target — a cross-filesystem mv is a copy, and a
# copy is not symlink-safe.
# Fixture addresses are RFC 5737 documentation space (192.0.2.0/24), which
# exists for exactly this and is outside every range the disclosure gate
# guards — so an example in a public repo never has to be argued about.
publish() {  # publish <override-file> <baked-file>
  rm -f "$TARGET"
  GA_SERVICES_CONF_OVERRIDE="$1" \
  GA_SERVICES_CONF_BAKED="$2" \
  GA_SHARE_TARGET="$TARGET" \
  GA_SHARE_PUBLISH="$SHARE_PUB" \
  GA_SHARE_STAGE_DIR="$STAGE" \
  "$PUB" 2>/dev/null
}

BAKED="$WORK/baked.conf"
OVER="$WORK/override.conf"

# --- the ordinary cases ------------------------------------------------------

printf 'GA_FLEET_HOST=example.invalid\nGA_SERVICES_IP=192.0.2.7\n' > "$BAKED"
publish "$WORK/absent.conf" "$BAKED"
run_test "GPS-02" "publishes the baked address" \
  "grep -q '\"ga_services_ip\":\"192.0.2.7\"' '$TARGET'"
run_test "GPS-03" "names where it came from" \
  "grep -q '\"source\":\"baked\"' '$TARGET'"

printf 'GA_SERVICES_IP=192.0.2.9\n' > "$OVER"
publish "$OVER" "$BAKED"
run_test "GPS-04" "the override wins over the baked file" \
  "grep -q '\"ga_services_ip\":\"192.0.2.9\"' '$TARGET'"
run_test "GPS-05" "and says so" "grep -q '\"source\":\"override\"' '$TARGET'"

# --- the shapes a KEY=VALUE file actually takes -------------------------------

printf 'GA_SERVICES_IP="192.0.2.11"\n' > "$OVER"
publish "$OVER" "$BAKED"
run_test "GPS-06" "double quotes are stripped" \
  "grep -q '\"ga_services_ip\":\"192.0.2.11\"' '$TARGET'"

printf "GA_SERVICES_IP='192.0.2.12'\n" > "$OVER"
publish "$OVER" "$BAKED"
run_test "GPS-07" "single quotes are stripped" \
  "grep -q '\"ga_services_ip\":\"192.0.2.12\"' '$TARGET'"

# The baked file on a real device carries the key inside comments too — three
# lines matched a naive grep when this was measured. A comment is not a value.
printf '# see GA_SERVICES_IP below\nGA_SERVICES_IP=192.0.2.13\n# resolved to GA_SERVICES_IP via /etc/hosts\n' > "$OVER"
publish "$OVER" "$BAKED"
run_test "GPS-08" "commented mentions are not values" \
  "grep -q '\"ga_services_ip\":\"192.0.2.13\"' '$TARGET'"

# `.`-sourcing takes the LAST assignment. Anything else would publish a value
# the host services themselves do not use.
printf 'GA_SERVICES_IP=192.0.2.1\nGA_SERVICES_IP=192.0.2.14\n' > "$OVER"
publish "$OVER" "$BAKED"
run_test "GPS-09" "last assignment wins, as sourcing would" \
  "grep -q '\"ga_services_ip\":\"192.0.2.14\"' '$TARGET'"

# --- absence is a fact, and must be published as one --------------------------

publish "$WORK/absent.conf" "$WORK/also-absent.conf"
run_test "GPS-10" "publishes even when there is no address at all" "test -f '$TARGET'"
run_test "GPS-11" "an absent address is an explicit null, not a missing file" \
  "grep -q '\"ga_services_ip\":null' '$TARGET'"
run_test "GPS-12" "and is labelled absent" "grep -q '\"source\":\"absent\"' '$TARGET'"

# An empty assignment is not an address. Publishing "" would hand the consumer
# a value that passes a truthiness check and means nothing.
printf 'GA_SERVICES_IP=\n' > "$OVER"
publish "$OVER" "$WORK/also-absent.conf"
run_test "GPS-13" "an empty assignment counts as absent" \
  "grep -q '\"ga_services_ip\":null' '$TARGET'"

# --- it must not execute the file it reads ------------------------------------

# The override lives on the data partition. Sourcing it would run whatever is
# in it as root.
printf 'GA_SERVICES_IP=192.0.2.15\ntouch %s/PWNED\n' "$WORK" > "$OVER"
publish "$OVER" "$BAKED"
run_test "GPS-14" "the conf file is parsed, never sourced" "test ! -e '$WORK/PWNED'"
run_test "GPS-15" "and the address is still read correctly" \
  "grep -q '\"ga_services_ip\":\"192.0.2.15\"' '$TARGET'"

# --- it publishes through the symlink-safe path -------------------------------

# /share is writable by every add-on that maps it. A plain `>` would follow a
# symlink planted at the target and write through it to a root-owned file.
printf 'GA_SERVICES_IP=192.0.2.16\n' > "$OVER"
VICTIM="$WORK/victim.conf"
printf 'original\n' > "$VICTIM"
rm -f "$TARGET"; ln -s "$VICTIM" "$TARGET"
GA_SERVICES_CONF_OVERRIDE="$OVER" GA_SERVICES_CONF_BAKED="$BAKED" \
GA_SHARE_TARGET="$TARGET" GA_SHARE_PUBLISH="$SHARE_PUB" GA_SHARE_STAGE_DIR="$STAGE" \
  "$PUB" 2>/dev/null
run_test "GPS-16" "a pre-planted symlink at the target is NOT followed" \
  "[ \"\$(cat '$VICTIM')\" = original ]"
run_test "GPS-17" "and the target is a regular file afterwards" \
  "[ -f '$TARGET' ] && [ ! -L '$TARGET' ]"

# --- the units that make it run ----------------------------------------------

UNITS="$OVERLAY/usr/lib/systemd/system"
WANTS="$OVERLAY/etc/systemd/system/multi-user.target.wants"
run_test "GPS-18" "service unit ships" "test -f '$UNITS/ga-publish-services.service'"
run_test "GPS-19" "path unit ships (republish when the override changes)" \
  "test -f '$UNITS/ga-publish-services.path'"
# A unit nobody enables never runs, and that failure is invisible: the file is
# present, correct, and asleep.
run_test "GPS-20" "service is enabled in the image" \
  "test -L '$WANTS/ga-publish-services.service' && test -e '$WANTS/ga-publish-services.service'"
run_test "GPS-21" "path unit is enabled in the image" \
  "test -L '$WANTS/ga-publish-services.path' && test -e '$WANTS/ga-publish-services.path'"
run_test "GPS-22" "the path unit watches the override the reconciler rewrites" \
  "grep -q 'PathChanged=/mnt/data/ga-services.conf' '$UNITS/ga-publish-services.path'"
run_test "GPS-23" "the path unit triggers the service" \
  "grep -q 'Unit=ga-publish-services.service' '$UNITS/ga-publish-services.path'"

rm -rf "$WORK"
suite_end
