# The host-lane test container.
#
# WHY THIS EXISTS. The host suites run scripts that are written for a DEVICE, and
# some of those scripts do device things. On 2026-08-28 the ga-rauc-install
# fixtures let the script's detached `( sleep 5 && systemctl reboot ) &` outlive
# the run: cleanup removed the PATH stubs, the orphan resolved the REAL systemctl,
# and the developer's laptop rebooted. Twice. The same suite on a GitHub runner
# would have rebooted the runner — systemd is present there too.
#
# A stub is a promise. This is a boundary: there is no systemd in here, no dbus,
# no init to talk to, so `systemctl reboot` cannot do anything but fail. The
# fixtures still stub it — defence in depth — but nothing now depends on them
# being correct.
#
# Debian trixie-slim matches what lint.yml's host-suites job runs on, so a green
# result here means the same thing it means in CI.
FROM debian:trixie-slim

# Patch the base rather than wait for a newer tag — same reasoning as the
# fleet-manager image: upstream rebuilds on its own schedule, not Debian's.
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && apt-get install -y --no-install-recommends jq ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# A non-root user, because a suite that needs root to pass is telling you
# something about itself.
RUN useradd -m -u 1000 runner
WORKDIR /repo
USER runner
