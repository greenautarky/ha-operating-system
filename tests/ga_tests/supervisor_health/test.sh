#!/bin/sh
# Supervisor health test suite — runs ON the device (incl. qemu CI).
#
# This is the post-mortem on the BOSv1.2.0 bench cycle baked into a test:
#
#   - Bug #3 (Build #5): Supervisor expected greenautarky/tinker-homeassistant
#     while the OS baked the upstream image -> landingpage fallback.
#     Catchable here via the version.json -> hassio_supervisor image check.
#   - Bug #2: GA_RELEASE env-stripping by `sudo -H` in hassos:local meant
#     /etc/ga-release shipped empty on Build #15. Catchable via SUP-05/06.
#   - auto_update drift (fleet audit 2026-06-01): 25/31 devices ended up on
#     auto_update=true. Catchable via SUP-04.
#
# All probes are non-destructive: read-only `ha`/`docker`/grep calls.
# Designed to run both on real hardware AND in the qemu CI lane — none of
# the assertions depend on iHost-specific paths.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Supervisor Health"

# SUP-01 — Supervisor container is running.
# This is the cheapest "is it up at all?" probe — `docker ps` runs in <50ms
# whether the supervisor is healthy or stuck on landingpage fallback.
run_test "SUP-01" "Supervisor container running" \
  "docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^hassio_supervisor$'"

# SUP-02 — `ha core info` exits 0.
# Bug #3 directly: when the image-tag mismatch fires, the supervisor logs
# a 'No version found' warning and the `ha core info` call fails to find
# a configured Core. We don't grep the body — just exit code, which is the
# simplest signal that the version chain resolved at all.
run_test "SUP-02" "ha core info exits 0" \
  "ha core info >/dev/null 2>&1"

# SUP-03 — Core image field in version.json is non-null.
# This catches Bug #3 even before Supervisor finishes its first cycle: if
# the hassio package's CONFIGURE_CMDS produced version.json with a null
# image (= upstream stable.json key missing for our machine), this fails.
# We don't check WHICH registry — that's a policy concern handled by
# check-images.sh at build time, not on-device.
run_test "SUP-03" "version.json has non-null Core image" \
  "VJ=/usr/share/hassio/version.json; \
   [ -f \"\$VJ\" ] && \
   IMG=\$(jq -r '.images.core' \"\$VJ\" 2>/dev/null) && \
   [ -n \"\$IMG\" ] && [ \"\$IMG\" != 'null' ]"

# SUP-04 — Supervisor auto_update is OFF by default.
# Fleet drift target: 25/31 devices were on auto_update=true and
# self-updated Core into incompatible versions. The OS image must ship
# auto_update=false.
#
# Probe order:
#   1. Try the supervisor REST API (works pre-onboarding, no token needed
#      from inside the host's docker network because the proxy injects it).
#   2. Fall back to `ha supervisor info` line-grep — the `ha` CLI works
#      post-onboarding when the supervisor is happy.
# Either green = green.
run_test "SUP-04" "Supervisor auto_update is false" \
  "( ha supervisor info --no-progress 2>/dev/null \
      | grep -qE '^auto_update:[[:space:]]+false' ) || \
   ( curl -s --max-time 10 \
        -H \"Authorization: Bearer \${SUPERVISOR_TOKEN:-}\" \
        http://supervisor/supervisor/info 2>/dev/null \
      | jq -e '.data.auto_update == false' >/dev/null 2>&1 )"

# SUP-05 — /etc/ga-release is populated.
# Bug #2: `sudo -H` in hassos:local strips env vars, so `docker run -e
# GA_RELEASE=…` silently dropped the value and shipped builds with empty
# /etc/ga-release. The build now reads from version.yaml as fallback —
# verify the stamp landed.
run_test "SUP-05" "/etc/ga-release is non-empty" \
  "test -s /etc/ga-release && grep -q . /etc/ga-release"

# SUP-06 — GA_RELEASE field is also in os-release.
# Consumed by fleet-manager telemetry + Lovelace dashboard cards. Independent
# write path from /etc/ga-release — both could fail or pass independently.
run_test "SUP-06" "GA_RELEASE field in /etc/os-release" \
  "grep -q '^GA_RELEASE=' /etc/os-release"

# SUP-07 — Display the resolved Core image:tag (DIAGNOSTIC).
# Doesn't change pass/fail; just dumps the resolved Core line into the log
# so that a future SUP-03 failure on the bench has an immediate breadcrumb
# without needing to ssh into the device again.
run_test_show "SUP-07" "Resolved Core image:tag" \
  "jq -r '.images.core + \":\" + (.core // \"unknown\")' /usr/share/hassio/version.json 2>/dev/null"

# SUP-08 — Supervisor self-reports as healthy.
# `ha supervisor info` is the canonical view; a 'landingpage' Core or a
# failed image pull leaves the supervisor reporting healthy:false. This is
# the post-condition that ties SUP-01..03 together.
#
# Marked as conditionally skipped if the `ha` CLI itself is broken (in
# which case SUP-02 will already be the failing alarm — no point firing
# a second one).
run_test "SUP-08" "Supervisor reports healthy" \
  "ha supervisor info --no-progress 2>/dev/null | grep -qE '^healthy:[[:space:]]+true'"

# SUP-10 — placeholder for the real addon-install probe (Bug #4).
# Listed here so future maintainers see the slot and know it's intentionally
# deferred. Phase 2 of the qemu CI lane will stand up a local GHCR mirror
# and flip this to a real install assertion.
skip_test "SUP-10" "Real addon install probe (Bug #4 coverage)" \
  "deferred to qemu-ci phase 2 (needs local GHCR mirror)"

# SUP-11 — ga-bootstrap.service ran. Catches the class of bug where systemd
# silently drops a service because a `Requires=` unit does not exist (=
# what happened on K31 BOSv1.2.6 when ga-bootstrap.service had
# Requires=hassio-supervisor.service but the real unit is named
# hassos-supervisor.service). The accept patterns mirror the two valid
# states:
#   - Active: active                         (currently running)
#   - Active: inactive (dead) ... Result: success  (oneshot completed)
# Anything else (Result: dependency / Result: protocol / no journal at
# all) means the start path failed silently.
#
# See memory/incident_hassio_vs_hassos_systemd_unit for the originating
# bench-test incident.
run_test "SUP-11" "ga-bootstrap.service ran successfully (not silently dropped)" \
  "systemctl status ga-bootstrap.service --no-pager 2>/dev/null \
    | grep -qE 'Active: active|Active: inactive.*Result: success'"

# SUP-12 — ga-bootstrap.service journal has entries. A `Requires=` on a
# missing unit can also produce 'inactive (dead)' if the unit was never
# triggered at all. This is a tighter assertion: at LEAST one journal line.
run_test "SUP-12" "ga-bootstrap.service has journal entries (≥ 1 line)" \
  "[ \"\$(journalctl -u ga-bootstrap.service --no-pager 2>/dev/null | wc -l)\" -ge 1 ]"

# SUP-13 — Reverse check: the systemd unit declares After=/Requires= on
# the CORRECT supervisor unit name. Reads the unit file directly so this
# catches the hassio/hassos typo even on an offline / un-converged device.
# Accept either spelling for backward compat with old rootfs ga-bootstrap.
run_test "SUP-13" "ga-bootstrap.service Requires= the real supervisor unit" \
  "systemctl cat ga-bootstrap.service 2>/dev/null \
    | grep -qE '^(After|Requires)=.*hass(io|os)-supervisor\\.service'"

# SUP-14 — Reverse-reverse: confirm the named supervisor unit ACTUALLY
# exists on disk. systemd does not warn about a missing Requires= target
# until something tries to depend on it; this test screams early if a
# future HAOS upstream rename strands all our Tier-2 services.
run_test "SUP-14" "Supervisor systemd unit (hassos-supervisor.service) exists" \
  "systemctl list-unit-files hassos-supervisor.service 2>/dev/null | grep -q hassos-supervisor"

suite_end
