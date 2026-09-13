#!/bin/sh
# RAUC slot-visibility suite (Odoo #561).
#
# Two halves:
#   * parser  — pure host-side, runs anywhere with sh + awk + jq. Feeds
#               captured `rauc status --detailed --output-format=shell`
#               fixtures through /usr/libexec/ga-rauc-slots and asserts the
#               published contract. No device needed.
#   * device  — asserts the collector is actually wired on a running device
#               (timer enabled, file present, fresh, agrees with rauc).
#               Skipped off-device.
#
# The property worth protecting: a slot that RAUC never installed into must
# NEVER be reported as a rollback target, even though the bootloader still
# calls it `boot status: good` (verified on a fresh SD flash, 2026-07-28).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "RAUC slots"

# Locate the collector: installed path on device, overlay path in-repo.
COL="/usr/libexec/ga-rauc-slots"
[ -x "$COL" ] || COL="$SCRIPT_DIR/../../../buildroot-external/rootfs-overlay/usr/libexec/ga-rauc-slots"
FIX="$SCRIPT_DIR/fixtures"

run_test "SLOT-20" "collector present + executable" "test -x '$COL'"

if ! command -v jq >/dev/null 2>&1; then
  skip_test "SLOT-21..SLOT-31" "parser contract" "jq not available"
else

WORK="$(mktemp -d 2>/dev/null || echo /tmp/rslots_$$)"
# Belt and braces to the collector-side guard: no invocation in this suite may
# fall through to the DEFAULT /mnt/data record. Exported once so a future call
# site cannot forget it — four of the seven here had.
GA_RAUC_SLOTS_BOOTS="${WORK}/boots.default.json"
export GA_RAUC_SLOTS_BOOTS
DEVICE_BOOTS_FILE=/mnt/data/ga-slot-boots.json
_dev_boots_before="$(cat "$DEVICE_BOOTS_FILE" 2>/dev/null || echo ABSENT)"
# Same for the mirror (content identity) record the collector keeps since
# 2026-09-13, and for the partitions it compares: a fixture run must never read
# THIS device's slots nor write its record. The collector refuses on its own
# when either redirect is missing; this makes the default safe as well.
GA_RAUC_SLOTS_MIRROR="${WORK}/mirror.default.json"
export GA_RAUC_SLOTS_MIRROR
DEVICE_MIRROR_FILE=/mnt/data/ga-slot-mirror.json
_dev_mirror_before="$(cat "$DEVICE_MIRROR_FILE" 2>/dev/null || echo ABSENT)"

# Run the collector against a fixture, leaving the JSON in $WORK/<name>.json.
parse_fixture() {
  # GA_RAUC_SLOTS_BOOTS is NOT optional here, and leaving it out was a real
  # incident on 2026-09-08. The collector records a healthy boot for the
  # fixture's booted slot on every run; without this the write lands in the
  # DEFAULT path, /mnt/data/ga-slot-boots.json — the device's persistent
  # rollback-safety evidence. The booted-from-b fixture then taught a live
  # canary that slot B had booted healthily, at the fixture's own timestamp
  # (1753790000). Consequence on that device: rollback.possible flipped to
  # true with target B, a slot with ever_installed=false and no installed
  # version — the exact "rollback onto an empty slot" this collector exists to
  # refuse. It also made this suite self-poisoning: green on its first run
  # against a device, red on every run after.
  GA_RAUC_SLOTS_TS=1753790000 \
  GA_RAUC_SLOTS_INPUT="$FIX/$1.shell" \
  GA_RAUC_SLOTS_BOOTS="$WORK/$1.boots.json" \
  GA_RAUC_SLOTS_OUT="$WORK/$1.json" \
  "$COL" >/dev/null 2>&1
}

# --- healthy dual-slot device (booted A, previous release still in B) --------
parse_fixture dual-slot-healthy
H="$WORK/dual-slot-healthy.json"

run_test "SLOT-21" "healthy: output is valid JSON carrying ts + no error" \
  "jq -e '.ts == 1753790000 and .error == null' '$H'"

run_test "SLOT-22" "healthy: booted slot A, rollback target B, rollback possible" \
  "jq -e '.booted == \"A\" and .rollback.current == \"A\" and .rollback.target == \"B\" and .rollback.possible == true and .rollback.reason == null' '$H'"

run_test "SLOT-23" "healthy: per-slot installed version read from the slot group" \
  "jq -e '(.slots | map({(.bootname): .installed_version}) | add) == {\"A\":\"16.3.1.9\",\"B\":\"16.3.1.8\"}' '$H'"

# The bootname lives on kernel.N while the OS version is recorded on both
# kernel.N and its rootfs.N child. Grouping parent+children is what makes
# install history readable regardless of which member RAUC wrote it to.
run_test "SLOT-24" "healthy: each slot groups its kernel + rootfs members" \
  "jq -e '(.slots[] | select(.bootname == \"A\") | .members) == [\"kernel.0\",\"rootfs.0\"]' '$H'"

# --- fresh SD flash: THE case this whole feature exists for ------------------
parse_fixture fresh-sd-flash
F="$WORK/fresh-sd-flash.json"

run_test "SLOT-25" "fresh flash: rollback is NOT possible (slot B never installed)" \
  "jq -e '.rollback.possible == false and .rollback.target == \"B\"' '$F'"

# grep, not jq's test(): the SHIPPED jq is built without Oniguruma, so
# test()/match()/sub() do not exist on the device and every such assertion fails
# with "jq was compiled without ONIGURUMA regex library" — a FAIL that looks
# exactly like a false assertion. Measured on K31 2026-07-30; this suite passed
# on the build host and failed on the device with an identical collector (same
# md5), which is what made it look like a real regression for an hour.
# Wording changed on 2026-08-19 and the old assertion was right to fail: the
# refusal has TWO grounds now (no install record AND no recorded healthy boot),
# so a message naming only the install record would be an incomplete reason for
# an operator deciding whether to force. Still greps for the consequence, which
# is the part that changes behaviour.
run_test "SLOT-26" "fresh flash: reason names BOTH missing evidences + the reflash consequence" \
  "jq -r '.rollback.reason' '$F' | grep -q 'NEITHER an OTA install record nor a recorded healthy boot' && \
   jq -r '.rollback.reason' '$F' | grep -q 're-flash'"

# Regression guard for the actual trap: boot_status is STILL 'good' on the
# empty slot. If a future refactor gates rollback on boot_status alone, this
# fixture goes green while the device bricks — so assert both halves.
run_test "SLOT-27" "fresh flash: empty slot B still reports boot_status=good (why boot_status is not the gate)" \
  "jq -e '(.slots[] | select(.bootname == \"B\")) | .boot_status == \"good\" and .ever_installed == false and .bootable == false' '$F'"

run_test "SLOT-28" "fresh flash: the BOOTED slot is bootable even with no install record" \
  "jq -e '(.slots[] | select(.bootname == \"A\")) | .ever_installed == false and .bootable == true' '$F'"

# --- slot present but condemned by the bootloader ---------------------------
parse_fixture slot-b-marked-bad
B="$WORK/slot-b-marked-bad.json"

run_test "SLOT-29" "marked-bad: rollback blocked, reason names the bootloader" \
  "jq -e '.rollback.possible == false' '$B' >/dev/null && \
   jq -r '.rollback.reason' '$B' | grep -q 'marked bad by the bootloader'"

# --- booted from B: nothing may hardcode A as the current slot --------------
parse_fixture booted-from-b
R="$WORK/booted-from-b.json"

run_test "SLOT-30" "booted from B: current is B and the rollback target is A" \
  "jq -e '.booted == \"B\" and .rollback.current == \"B\" and .rollback.target == \"A\" and .rollback.possible == true' '$R'"

# --- fail closed ------------------------------------------------------------
: > "$WORK/empty.shell"
GA_RAUC_SLOTS_TS=1753790000 GA_RAUC_SLOTS_INPUT="$WORK/empty.shell" \
  GA_RAUC_SLOTS_OUT="$WORK/empty.json" "$COL" >/dev/null 2>&1
run_test "SLOT-31a" "rauc silent: publishes an error record, never a bootable-looking one" \
  "jq -e '.error != null and .slots == [] and .rollback.possible == false' '$WORK/empty.json'"

printf 'this is not rauc output\nneither is this\n' > "$WORK/garbage.shell"
GA_RAUC_SLOTS_TS=1753790000 GA_RAUC_SLOTS_INPUT="$WORK/garbage.shell" \
  GA_RAUC_SLOTS_OUT="$WORK/garbage.json" "$COL" >/dev/null 2>&1
run_test "SLOT-31b" "unparseable rauc output: error record, rollback not possible" \
  "jq -e '.error != null and .rollback.possible == false' '$WORK/garbage.json'"

fi

# --- static: where it publishes, and that it never executes rauc output ------
# The published file is not a readout, it is the input to a rollback decision.
# /share is writable by every add-on declaring `share:rw`, all running as host
# uid 0 — three installed add-ons on the current image, all ours, but the
# customer can add to that set with one line of add-on metadata. Whoever is on
# that bus could forge "rollback.possible: true" onto a device whose second
# slot is empty and have an operator brick it. The add-on-private data dir is
# the one channel they cannot reach.
run_test "SLOT-33a" "publishes into the add-on-private data dir" \
  "grep -v '^[[:space:]]*#' '$COL' | grep -q '/mnt/data/supervisor/addons/data/\*_ga_manager'"

run_test "SLOT-33b" "never writes the slot picture into the add-on-writable /share" \
  "! grep -v '^[[:space:]]*#' '$COL' | grep -q 'supervisor/share'"

# No add-on installed yet = no data dir. Publishing must be a no-op rather
# than creating a directory Supervisor did not make.
# On a DEVICE with ga_manager installed the real glob matches, so the collector
# correctly publishes and this negative case cannot be constructed. Asserting it
# anyway made it fail on every provisioned device — a red check that says nothing
# about the device. It stays a real test on the build host, where the glob is
# genuinely empty.
if ls -d /mnt/data/supervisor/addons/data/*_ga_manager >/dev/null 2>&1; then
  skip_test "SLOT-34" "no-add-on-dir behaviour" "ga_manager IS installed here — the not-yet-installed case cannot be constructed on a live device"
elif command -v jq >/dev/null 2>&1; then
  NODIR="$(mktemp -d 2>/dev/null || echo /tmp/rslots_nodir_$$)"
  # No GA_RAUC_SLOTS_OUT: the collector resolves the real add-on glob, which
  # matches nothing on a build host — exactly the not-yet-installed case.
  GA_RAUC_SLOTS_TS=1753790000 \
  GA_RAUC_SLOTS_INPUT="$FIX/dual-slot-healthy.shell" \
  "$COL" >/dev/null 2>"$NODIR/err"
  run_test "SLOT-34" "no add-on data dir: publishes nothing, exits clean" \
    "[ ! -e '$NODIR/ga-rauc-slots.json' ] && grep -q 'publishing nothing' '$NODIR/err'"
  rm -rf "$NODIR"
else
  skip_test "SLOT-34" "no-add-on-dir behaviour" "jq not available"
fi

# /usr/libexec/raucdb-update does `eval "$(rauc status ...)"`. This collector
# deliberately does not: it runs as root and the habit is worth keeping out of
# new code. Cheap static guard so it cannot creep back in.
run_test "SLOT-32" "collector never evals or sources rauc output" \
  "! grep -v '^[[:space:]]*#' '$COL' | grep -Eq '(^|[^[:alnum:]_])(eval|source)[[:space:]]|^[[:space:]]*\\.[[:space:]]'"

# =========================================================================
# Healthy-boot evidence (2026-08-19) — the second, independent rollback ground
# =========================================================================
# The gap this closes, measured on K31 2026-08-18: an SD flash writes no RAUC
# slot metadata, so the moment the device booted B, slot A read
# ever_installed=false even though it had booted A minutes earlier. A new device
# had NO rollback target, and its first OTA was un-rollback-able by construction.
#
# These cases assert the evidence is EARNED, not assumed: recorded only after the
# uptime threshold (a boot-looping slot never qualifies), and honoured only when
# the bootloader has not given up on the slot.

# Same fresh-flash fixture as SLOT-25..28 — booted A, B empty, no install record
# anywhere — driven with a boot record and a faked uptime.
run_with_boots() { # run_with_boots <fixture> <boots-json> <uptime-s> <out-name>
  printf '%s' "$2" > "$WORK/$4.boots.json"
  GA_RAUC_SLOTS_TS=1753790000 \
  GA_RAUC_SLOTS_INPUT="$FIX/$1.shell" \
  GA_RAUC_SLOTS_OUT="$WORK/$4.json" \
  GA_RAUC_SLOTS_BOOTS="$WORK/$4.boots.json" \
  GA_RAUC_SLOTS_UPTIME="$3" \
  "$COL" >/dev/null 2>&1
}

# --- no record: unchanged refusal (the guard still guards) --------------------
run_with_boots fresh-sd-flash '{}' 60 boots-none
B0="$WORK/boots-none.json"
run_test "SLOT-50" "no boot record: rollback still refused (nothing regressed)" \
  "jq -e '.rollback.possible == false' '$B0'"
run_test "SLOT-51" "no boot record: target reports booted_ok=false" \
  "jq -e '[.slots[] | select(.bootname == \"B\")] | .[0].booted_ok == false' '$B0'"

# --- a recorded healthy boot of the TARGET makes it a target ------------------
run_with_boots fresh-sd-flash '{"B":{"at":1753700000,"uptime_s":1200}}' 60 boots-b
B1="$WORK/boots-b.json"
run_test "SLOT-52" "recorded healthy boot of B: rollback becomes possible" \
  "jq -e '.rollback.possible == true and .rollback.target == \"B\"' '$B1'"
run_test "SLOT-53" "recorded healthy boot is reported as its OWN field, not as an install" \
  "jq -e '[.slots[] | select(.bootname == \"B\")] | .[0] | .booted_ok == true and .ever_installed == false and .installed_timestamp == null' '$B1'"
run_test "SLOT-54" "rollback possible: no refusal reason is invented" \
  "jq -e '.rollback.reason == null' '$B1'"

# --- a record for the WRONG slot must not promote the target ------------------
# The bug this catches: keying the evidence on "any record exists" rather than on
# the target slot. A device that has only ever booted A would then look ready to
# roll back INTO the empty B.
run_with_boots fresh-sd-flash '{"A":{"at":1753700000,"uptime_s":1200}}' 60 boots-a
B2="$WORK/boots-a.json"
run_test "SLOT-55" "record for A only: rollback into the empty B stays refused" \
  "jq -e '.rollback.possible == false and .rollback.target == \"B\"' '$B2'"

# --- the bootloader still overrides the evidence ------------------------------
# slot-b-marked-bad has B marked bad. A healthy-boot record must NOT rescue it:
# boot_status good is required for both non-booted grounds.
run_with_boots slot-b-marked-bad '{"B":{"at":1753700000,"uptime_s":1200}}' 60 boots-bad
B3="$WORK/boots-bad.json"
run_test "SLOT-56" "marked-bad beats a boot record: rollback refused, reason names the bootloader" \
  "jq -e '.rollback.possible == false' '$B3' && jq -r '.rollback.reason' '$B3' | grep -q 'bootloader'"

# --- the record is EARNED: below the threshold nothing is written -------------
# This is the half that makes the evidence honest. A slot that boots and dies is
# not a rollback target, so the record only appears once the device has been up
# past the threshold.
run_with_boots fresh-sd-flash '{}' 60 boots-early
run_test "SLOT-57" "uptime below the threshold: nothing recorded (a boot loop never qualifies)" \
  "jq -e '. == {}' '$WORK/boots-early.boots.json'"

run_with_boots fresh-sd-flash '{}' 900 boots-late
run_test "SLOT-58" "uptime past the threshold: the BOOTED slot is recorded, with its uptime" \
  "jq -e '.A.uptime_s == 900 and .A.at == 1753790000' '$WORK/boots-late.boots.json'"
run_test "SLOT-59" "recording is per-slot and does not invent an entry for the other slot" \
  "jq -e 'has(\"B\") == false' '$WORK/boots-late.boots.json'"

# --- a corrupt record must read as NO evidence, never as permission ----------
printf 'this is not json' > "$WORK/boots-corrupt.boots.json"
GA_RAUC_SLOTS_TS=1753790000 GA_RAUC_SLOTS_INPUT="$FIX/fresh-sd-flash.shell" \
  GA_RAUC_SLOTS_OUT="$WORK/boots-corrupt.json" \
  GA_RAUC_SLOTS_BOOTS="$WORK/boots-corrupt.boots.json" \
  GA_RAUC_SLOTS_UPTIME=60 "$COL" >/dev/null 2>&1
run_test "SLOT-60" "unparseable boot record: refused, and the collector still publishes" \
  "jq -e '.rollback.possible == false and .error == null' '$WORK/boots-corrupt.json'"

# =========================================================================
# Mirror evidence (2026-09-13) — the third, independent rollback ground
# =========================================================================
# Since #349 the image writes the same kernel and rootfs into BOTH slot pairs,
# so a fresh flash carries a complete OS in the inactive slot. Neither an
# install record nor a healthy boot can see that, so every fresh device kept
# reporting rollback.possible=false (measured on a fresh flash, 2026-09-13:
# "target=B possible=false reason=slot B has NEITHER ..."). The collector now
# compares the inactive slot group with the booted one, byte for byte, on the
# device — and that is the evidence asserted here, with the partitions
# replaced by files under GA_RAUC_SLOTS_DEVROOT.
#
# The predicate under test is the ONE the live check (SLOT-46) applies to the
# device snapshot, so red and green are proven on every PR: SLOT-70 is the
# post-change fresh flash (identical slots) and must be possible=true; SLOT-71
# is the pre-#349 fresh flash (empty B) and must stay false.
rollback_possible_verdict() { # rollback_possible_verdict <json>  -> 0 if possible
  if jq -e '.rollback.possible == true' "$1" >/dev/null 2>&1; then
    jq -r '.rollback | "target=" + (.target // "none") + " possible=true"' "$1"
    return 0
  fi
  jq -r '"target=" + (.rollback.target // "none") + " possible=" + (.rollback.possible|tostring)
         + " evidence(install=" + ([.slots[] | select(.booted|not)][0].ever_installed|tostring)
         + " boot=" + ([.slots[] | select(.booted|not)][0].booted_ok|tostring)
         + " mirror=" + ([.slots[] | select(.booted|not)][0].mirror_of_booted|tostring)
         + ") reason=" + (.rollback.reason // "-")' "$1"
  return 1
}

if command -v jq >/dev/null 2>&1 && command -v cmp >/dev/null 2>&1; then
# A fake device: files named like the partlabels the fixtures reference.
# Content is small but not trivial — a kernel-ish header and some filler — so
# that "identical" and "different" are both real comparisons.
DEV="$WORK/dev"
mk_dev() { # mk_dev <kernel1 = identical|zero|absent|different> <system1 = identical|zero|different>
  rm -rf "$DEV"; mkdir -p "$DEV"
  printf 'GAOS-KERNEL-IMAGE\000\001\002' > "$DEV/hassos-kernel0"
  head -c 4096 /dev/zero | tr '\000' 'k' >> "$DEV/hassos-kernel0"
  printf 'GAOS-ROOTFS-IMAGE\000\001\002' > "$DEV/hassos-system0"
  head -c 8192 /dev/zero | tr '\000' 'r' >> "$DEV/hassos-system0"
  case "$1" in
    identical) cp "$DEV/hassos-kernel0" "$DEV/hassos-kernel1" ;;
    zero)      head -c "$(wc -c < "$DEV/hassos-kernel0")" /dev/zero > "$DEV/hassos-kernel1" ;;
    different) cp "$DEV/hassos-kernel0" "$DEV/hassos-kernel1"; printf 'X' >> "$DEV/hassos-kernel1" ;;
    absent)    : ;;
  esac
  case "$2" in
    identical) cp "$DEV/hassos-system0" "$DEV/hassos-system1" ;;
    zero)      head -c "$(wc -c < "$DEV/hassos-system0")" /dev/zero > "$DEV/hassos-system1" ;;
    different) head -c 4096 "$DEV/hassos-system0" > "$DEV/hassos-system1" ;;
  esac
}
# run_mirror <fixture> <boots-json> <mirror-json|-> <out-name>
run_mirror() {
  printf '%s' "$2" > "$WORK/$4.boots.json"
  if [ "$3" = "-" ]; then rm -f "$WORK/$4.mirror.json"; else printf '%s' "$3" > "$WORK/$4.mirror.json"; fi
  GA_RAUC_SLOTS_TS=1753790000 \
  GA_RAUC_SLOTS_INPUT="$FIX/$1.shell" \
  GA_RAUC_SLOTS_OUT="$WORK/$4.json" \
  GA_RAUC_SLOTS_BOOTS="$WORK/$4.boots.json" \
  GA_RAUC_SLOTS_MIRROR="$WORK/$4.mirror.json" \
  GA_RAUC_SLOTS_DEVROOT="$DEV" \
  GA_RAUC_SLOTS_UPTIME=60 \
  "$COL" >/dev/null 2>"$WORK/$4.err"
}

# --- fresh flash of a post-#349 image: both pairs identical -----------------
mk_dev identical identical
run_mirror fresh-sd-flash '{}' - mirror-same
M1="$WORK/mirror-same.json"
run_test_show "SLOT-70" "fresh flash, slot B byte-identical to booted A: rollback IS possible" \
  "rollback_possible_verdict '$M1'"
run_test "SLOT-71" "identical slot: evidence is its OWN field, not an install record and not a version" \
  "jq -e '[.slots[] | select(.bootname == \"B\")] | .[0] | .mirror_of_booted == true and .ever_installed == false and .booted_ok == false and .installed_version == null and .bootable == true' '$M1'"
run_test "SLOT-72" "identical slot: no refusal reason is invented" \
  "jq -e '.rollback.reason == null' '$M1'"
run_test "SLOT-73" "the measurement is recorded: target, compared-with slot, verdict, member pairs" \
  "jq -e '.B.of == \"A\" and .B.identical == true and .B.at == 1753790000 and .B.members == {\"kernel.1\":\"kernel.0\",\"rootfs.1\":\"rootfs.0\"}' '$WORK/mirror-same.mirror.json'"

# --- fresh flash of a pre-#349 image: slot B is all zeros --------------------
# The same predicate as SLOT-70 must go RED here. This is what the live check
# would have said on every fresh device before this change.
mk_dev zero zero
run_mirror fresh-sd-flash '{}' - mirror-zero
M2="$WORK/mirror-zero.json"
run_test "SLOT-74" "fresh flash, slot B empty: rollback stays refused, and the reason says the content differs" \
  "! rollback_possible_verdict '$M2' >/dev/null && jq -r '.rollback.reason' '$M2' | grep -q 'content differs from the booted slot' && jq -e '[.slots[] | select(.bootname == \"B\")] | .[0].mirror_of_booted == false' '$M2'"

# --- a flash that stopped half-way: kernel identical, rootfs not -------------
# Every member of the group has to match. A kernel that boots into a rootfs that
# is not there is the reboot loop this whole file exists to prevent.
mk_dev identical different
run_mirror fresh-sd-flash '{}' - mirror-partial
run_test "SLOT-75" "kernel identical but rootfs differs: refused (every member must match)" \
  "jq -e '.rollback.possible == false and ([.slots[] | select(.bootname == \"B\")] | .[0].mirror_of_booted == false)' '$WORK/mirror-partial.json'"

# --- RAUC has touched the slot: the identity evidence is dead ----------------
# status=pending on kernel.1, no timestamp (RAUC 1.13 writes that before it
# writes the slot). Content is identical on disk — and must NOT count.
mk_dev identical identical
run_mirror slot-b-install-pending '{}' - mirror-pending
run_test "SLOT-76" "install pending on B: content identity is not consulted, rollback refused" \
  "jq -e '.rollback.possible == false and ([.slots[] | select(.bootname == \"B\")] | .[0] | .mirror_of_booted == null and .install_status == \"pending\")' '$WORK/mirror-pending.json' && [ ! -s '$WORK/mirror-pending.mirror.json' ]"

# --- the bootloader still overrides the evidence -----------------------------
mk_dev identical identical
run_mirror slot-b-marked-bad '{}' - mirror-bad
run_test "SLOT-77" "marked-bad beats identical content: refused, reason names the bootloader" \
  "jq -e '.rollback.possible == false' '$WORK/mirror-bad.json' && jq -r '.rollback.reason' '$WORK/mirror-bad.json' | grep -q 'bootloader'"

# --- the record is reused only against the slot it was measured with --------
# A cached "identical" that was measured while B was booted says nothing about
# B versus A now. With B empty on disk, a stale record must not promote it.
mk_dev zero zero
run_mirror fresh-sd-flash '{}' '{"B":{"of":"B","identical":true,"at":1,"members":{}}}' mirror-stale
run_test "SLOT-78" "record measured against another booted slot is stale: re-measured, refused" \
  "jq -e '.rollback.possible == false' '$WORK/mirror-stale.json' && jq -e '.B.of == \"A\" and .B.identical == false' '$WORK/mirror-stale.mirror.json'"

# --- one read per device lifetime: a valid record is not re-measured --------
# Same booted slot, record says identical — the partitions are not read again.
# Proven by making them unreadable (absent): a re-measurement would find no
# device and produce no verdict; the cached one carries.
mk_dev absent identical
rm -f "$DEV/hassos-system1"
run_mirror fresh-sd-flash '{}' '{"B":{"of":"A","identical":true,"at":1753700000,"members":{"kernel.1":"kernel.0","rootfs.1":"rootfs.0"}}}' mirror-cached
run_test "SLOT-79" "valid record for the booted slot is reused: no re-read, rollback possible" \
  "jq -e '.rollback.possible == true' '$WORK/mirror-cached.json' && jq -e '.B.at == 1753700000' '$WORK/mirror-cached.mirror.json'"

# --- a healthy-boot record already settles it: nothing is read from disk ----
mk_dev zero zero
run_mirror fresh-sd-flash '{"B":{"at":1753700000,"uptime_s":1200}}' - mirror-booted
run_test "SLOT-80" "recorded healthy boot of B: possible, and no comparison is made (nothing written)" \
  "jq -e '.rollback.possible == true' '$WORK/mirror-booted.json' && [ ! -s '$WORK/mirror-booted.mirror.json' ]"

# --- fixture input without a device root: never touch the real partitions ---
mk_dev identical identical
printf '{}' > "$WORK/mirror-noroot.boots.json"
rm -f "$WORK/mirror-noroot.mirror.json"
GA_RAUC_SLOTS_TS=1753790000 GA_RAUC_SLOTS_INPUT="$FIX/fresh-sd-flash.shell" \
  GA_RAUC_SLOTS_OUT="$WORK/mirror-noroot.json" GA_RAUC_SLOTS_BOOTS="$WORK/mirror-noroot.boots.json" \
  GA_RAUC_SLOTS_MIRROR="$WORK/mirror-noroot.mirror.json" GA_RAUC_SLOTS_UPTIME=60 \
  "$COL" >/dev/null 2>&1
run_test "SLOT-81" "fixture input without GA_RAUC_SLOTS_DEVROOT: not measured, nothing recorded, refused" \
  "jq -e '.rollback.possible == false and ([.slots[] | select(.bootname == \"B\")] | .[0].mirror_of_booted == null)' '$WORK/mirror-noroot.json' && [ ! -s '$WORK/mirror-noroot.mirror.json' ]"

# --- a corrupt record reads as NO evidence, and is re-measured ---------------
mk_dev identical identical
run_mirror fresh-sd-flash '{}' 'this is not json' mirror-corrupt
run_test "SLOT-82" "unparseable mirror record: re-measured from scratch, collector still publishes" \
  "jq -e '.rollback.possible == true and .error == null' '$WORK/mirror-corrupt.json' && jq -e '.B.identical == true' '$WORK/mirror-corrupt.mirror.json'"
else
  skip_test "SLOT-70..SLOT-82" "mirror evidence" "jq or cmp not available"
fi

# =========================================================================
# Device-side wiring (skipped off-device)
# =========================================================================
if [ ! -d /mnt/data/supervisor ]; then
  skip_test "SLOT-40..SLOT-45" "on-device collector wiring" "not running on a GA device"
else
  run_test "SLOT-40" "ga-rauc-slots.timer enabled" \
    "systemctl is-enabled ga-rauc-slots.timer"

  # Slug carries a repo hash, so resolve by glob (ga-bootstrap 1.2.5 form).
  SHARE_JSON="$(ls -1 /mnt/data/supervisor/addons/data/*_ga_manager/ga-rauc-slots.json 2>/dev/null | head -1)"
  [ -n "$SHARE_JSON" ] || SHARE_JSON=/nonexistent
  run_test "SLOT-41" "slot snapshot published to the add-on-private data dir" \
    "test -s '$SHARE_JSON'"

  run_test "SLOT-45" "slot snapshot is NOT in the add-on-writable /share" \
    "[ ! -e /mnt/data/supervisor/share/ga-rauc-slots.json ]"

  if [ -s "$SHARE_JSON" ] && command -v jq >/dev/null 2>&1; then
    # The addon treats anything older than 3 missed 10min ticks as stale and
    # degrades to unknown; assert the collector keeps it inside that window.
    run_test "SLOT-42" "snapshot fresher than the addon's 35min staleness window" \
      "[ \$(( \$(date +%s) - \$(jq -r '.ts' '$SHARE_JSON') )) -lt 2100 ]"

    run_test "SLOT-43" "snapshot agrees with live rauc on the booted slot" \
      "[ \"\$(jq -r '.booted' '$SHARE_JSON')\" = \"\$(rauc status --output-format=shell 2>/dev/null | sed -n \"s/^RAUC_SYSTEM_BOOTED_BOOTNAME='\\(.*\\)'\$/\\1/p\")\" ]"

    run_test_show "SLOT-44" "rollback target + verdict on this device" \
      "jq -r '\"target=\" + (.rollback.target // \"none\") + \" possible=\" + (.rollback.possible|tostring) + \" reason=\" + (.rollback.reason // \"-\")' '$SHARE_JSON'"

    # SLOT-46 turns SLOT-44's readout into an assertion. The image has carried a
    # complete OS in BOTH slots since #349, so a device whose rollback target is
    # not bootable is a finding, not a state: on a fresh flash it means the
    # collector found no evidence for slot B (this was every fresh device until
    # 2026-09-13); on an OTA'd device it means the previous release is not there
    # to go back to. Reads the published snapshot — what the fleet-manager
    # pre-flight reads — and runs nothing that could write device state.
    # Same predicate as SLOT-70/74, which prove it red and green on every PR.
    run_test_show "SLOT-46" "the rollback target on this device is bootable (evidence, not assumption)" \
      "rollback_possible_verdict '$SHARE_JSON'"
  else
    skip_test "SLOT-42..SLOT-44" "snapshot content checks" "no snapshot or jq unavailable"
    skip_test "SLOT-46" "rollback target bootable" "no snapshot or jq unavailable"
  fi
fi

# --- the suite must not teach the device anything --------------------------
# SLOT-61 exists because this suite once did. Running it against a live canary
# wrote the booted-from-b fixture's healthy-boot evidence into the DEVICE's
# persistent /mnt/data/ga-slot-boots.json, at the fixture timestamp. The device
# then reported rollback.possible=true onto a slot with ever_installed=false —
# the precise outcome this collector exists to refuse — and the suite, having
# poisoned its own input, failed on every run after the first.
# Compares the device file before and after: a test that changes the system it
# measures has no verdict to give.
_dev_boots_after="$(cat "$DEVICE_BOOTS_FILE" 2>/dev/null || echo ABSENT)"
if [ "$_dev_boots_before" = "$_dev_boots_after" ]; then
  run_test "SLOT-61" "the suite did not write the device healthy-boot record" "true"
else
  run_test "SLOT-61" "the suite did not write the device healthy-boot record" "false"
  printf '        %s changed while this suite ran.\n' "$DEVICE_BOOTS_FILE"
  printf '        before: %s\n' "$_dev_boots_before"
  printf '        after : %s\n' "$_dev_boots_after"
  printf '        A collector invocation is missing GA_RAUC_SLOTS_BOOTS, or the\n'
  printf '        fixture guard in record_healthy_boot was removed.\n'
fi

# Same guard for the mirror record: a fixture run must never measure THIS
# device's partitions nor persist a verdict about them.
_dev_mirror_after="$(cat "$DEVICE_MIRROR_FILE" 2>/dev/null || echo ABSENT)"
if [ "$_dev_mirror_before" = "$_dev_mirror_after" ]; then
  run_test "SLOT-62" "the suite did not write the device mirror record" "true"
else
  run_test "SLOT-62" "the suite did not write the device mirror record" "false"
  printf '        %s changed while this suite ran.\n' "$DEVICE_MIRROR_FILE"
  printf '        before: %s\n' "$_dev_mirror_before"
  printf '        after : %s\n' "$_dev_mirror_after"
  printf '        A collector invocation is missing GA_RAUC_SLOTS_MIRROR or\n'
  printf '        GA_RAUC_SLOTS_DEVROOT, or the fixture guard in measure_mirror\n'
  printf '        was removed.\n'
fi

[ -n "${WORK:-}" ] && rm -rf "$WORK"

suite_end
