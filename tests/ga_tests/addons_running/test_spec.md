# addons_running — provisioned device, no fleet-manager

The WORKING line for the add-on set: installed, Up, and answering — probed via
docker/localhost only, deliberately independent of the fleet-manager. Born
2026-08-20 with the Stage-2 base migration, whose builds could not prove:
pandas 3.x imports at runtime (ADR-13), go-auth CGO loads on the new libc
(ADR-11), Node 24 executes on real armv7 (ADR-15). ADR-08 asserts the dongle
flasher is NOT running (ga_manager stops it — the 2026-08-19 finding); ADR-20
catches crash loops that up-ness cannot see (RestartCount).

Run AFTER provisioning/converge. On a fresh unprovisioned flash everything is
legitimately red — that is the suite's red proof, not a defect.
