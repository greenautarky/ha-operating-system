#!/usr/bin/env python3
"""Lint the systemd units this tree ships: every unit they name must exist, and
start-rate limits must sit where systemd reads them.

WHY THIS EXISTS
---------------
systemd does not fail on a dependency or ordering directive that names a unit
which does not exist. `After=`/`Before=` against a missing unit is a silent
no-op; `Wants=` is too; `Requires=` drops the dependent unit's start job with
"Result: dependency" and nothing else. `systemd-analyze verify` passes over all
of it. So a unit that is renamed, or a name that is simply misspelled, turns an
ordering the code relies on into nothing, with no error anywhere.

That happened: GA units ordered themselves against `hassio-supervisor.service`,
while the unit this image ships is `hassos-supervisor.service`. One of them
documents its `Before=` as the guard against a race with the Supervisor. The
guard was never in effect. (An earlier instance of the same name, a
`Requires=`, silently dropped ga-bootstrap.service; see SUP-11.)

Second class, same silence: the start-rate limit keys belong in `[Unit]`.
systemd 257 still accepts `StartLimitBurst=`, `StartLimitInterval=` and
`StartLimitAction=` in `[Service]` for compatibility, but NOT
`StartLimitIntervalSec=`: there it logs "Unknown key ... ignoring" (measured
with systemd-analyze verify). Written in `[Service]`, the burst is then counted
against the 10 s default interval, so a limit like "10 starts in 300 s" becomes
"10 starts in 10 s", which a unit restarting every 5 s never reaches. All four
keys are flagged in `[Service]`, so a limit is always declared in one place,
`[Unit]`, where every spelling works.

WHAT IT CHECKS
--------------
(a) In `[Unit]`: After, Before, Wants, Requires, Requisite, BindsTo, PartOf,
    Upholds, Conflicts, OnFailure, OnSuccess. In `[Install]`: WantedBy,
    RequiredBy, UpheldBy, Also. Every named unit must be
      - a unit file shipped in this tree (a file or alias symlink with a unit
        suffix, outside *.wants/ *.requires/ *.upholds/ link directories),
      - or a name declared by `Alias=` in a shipped unit,
      - or an instance `foo@bar.x` of a shipped template `foo@.x`,
      - or listed in BASE_UNITS below (units provided by systemd or by a
        Buildroot package rather than by a file in this tree),
      - or a `.device` unit (synthesised from udev at runtime).
    Names containing a specifier (`%i`, `%n`, ...) are not resolvable
    statically and are skipped.
(b) StartLimitIntervalSec / StartLimitInterval / StartLimitBurst /
    StartLimitAction inside `[Service]`.

Unit files AND drop-ins (`<unit>.d/*.conf`) are read. The unit set is the union
of every tree given, i.e. of all boards: a board-tree unit named from a generic
unit resolves here even for a board that does not ship it. Narrower checks are
a per-image job, not a source lint.

Fails closed: zero unit files found is exit 2, never a pass.

Usage: check-unit-refs.py [TREE ...]   (default: buildroot-external buildroot-ihost)
Exit:  0 clean · 1 findings · 2 nothing inspected / usage error
"""
import os
import re
import sys

UNIT_SUFFIXES = (
    ".service", ".socket", ".target", ".mount", ".automount", ".swap",
    ".path", ".timer", ".slice", ".scope", ".device",
)

UNIT_DEP_KEYS = {
    "After", "Before", "Wants", "Requires", "Requisite", "BindsTo", "PartOf",
    "Upholds", "Conflicts", "OnFailure", "OnSuccess",
}
INSTALL_DEP_KEYS = {"WantedBy", "RequiredBy", "UpheldBy", "Also"}
START_LIMIT_KEYS = {
    "StartLimitIntervalSec", "StartLimitInterval", "StartLimitBurst",
    "StartLimitAction",
}

# Units the image has WITHOUT a file in this tree. Each entry says who provides
# it. Keep this short: every entry is a name the lint can no longer check, so an
# entry is added only for a unit that exists on the device (or, marked ABSENT, a
# no-op ordering copied verbatim from an upstream unit) — never to make a
# finding go away. `systemctl cat <name>` on a device is the proof.
# Every entry is referenced by at least one shipped unit; an unreferenced entry
# is reported, so the list cannot grow stale.
BASE_UNITS = {
    # --- systemd special targets, systemd.special(7) ---
    "basic.target": "systemd",
    "sysinit.target": "systemd",
    "multi-user.target": "systemd",
    "local-fs.target": "systemd",
    "network.target": "systemd",
    "network-pre.target": "systemd",
    "network-online.target": "systemd",
    "time-sync.target": "systemd",
    "sockets.target": "systemd",
    "timers.target": "systemd",
    "paths.target": "systemd",
    "swap.target": "systemd",
    "sound.target": "systemd",
    "shutdown.target": "systemd",
    "umount.target": "systemd",
    "getty.target": "systemd",
    "getty-pre.target": "systemd",
    # --- systemd services, sockets, mounts, templates ---
    "rescue.service": "systemd",
    "systemd-journald.service": "systemd",
    "systemd-journald.socket": "systemd",
    "systemd-journal-flush.service": "systemd",
    "systemd-udevd.service": "systemd",
    "systemd-udev-trigger.service": "systemd",
    "systemd-modules-load.service": "systemd",
    "systemd-sysctl.service": "systemd",
    "systemd-user-sessions.service": "systemd",
    "systemd-timesyncd.service": "systemd",
    "systemd-fsck@.service": "systemd (template; instances per partition label)",
    "tmp.mount": "systemd",
    # --- Buildroot packages selected by the defconfigs ---
    "dbus.socket": "dbus-broker (Buildroot)",
    "docker.service": "docker-engine (Buildroot)",
    "rauc.service": "rauc (Buildroot)",
    "NetworkManager.service": "network-manager (Buildroot)",
    "NetworkManager-wait-online.service": "network-manager (Buildroot)",
    "bluetooth.service": "bluez5_utils (Buildroot)",
    "sshd.service": "openssh (Buildroot)",
    # --- ABSENT on the image: no-op orderings kept verbatim from upstream ---
    "plymouth-quit-wait.service": "ABSENT (no plymouth); line copied from systemd's getty@.service into upstream ha-cli@.service",
    "syslog.target": "ABSENT (legacy name); upstream lxd-agent.service, VM-only package",
}


def is_unit_name(name):
    return name.endswith(UNIT_SUFFIXES)


def parse(path):
    """Yield (lineno, section, key, value) with continuation lines joined."""
    # An unreadable unit file raises: a file the lint cannot read is not a pass.
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().split("\n")
    section = None
    i = 0
    while i < len(lines):
        start = i
        line = lines[i].rstrip()
        i += 1
        stripped = line.lstrip()
        if not stripped or stripped[0] in "#;":
            continue
        while line.endswith("\\") and i < len(lines):
            line = line[:-1] + " " + lines[i].strip()
            i += 1
        stripped = line.strip()
        m = re.match(r"^\[([^\]]+)\]$", stripped)
        if m:
            section = m.group(1)
            continue
        if "=" in stripped:
            key, _, value = stripped.partition("=")
            yield start + 1, section, key.strip(), value.strip()


def collect(trees):
    units = []      # unit files and drop-ins to parse
    defined = set()  # unit names that exist
    for tree in trees:
        for dirpath, dirnames, filenames in os.walk(tree, followlinks=False):
            dirnames[:] = [d for d in dirnames if d != ".git"]
            parent = os.path.basename(dirpath)
            link_dir = parent.endswith((".wants", ".requires", ".upholds"))
            dropin_dir = parent.endswith(".d") and is_unit_name(parent[:-2])
            for fn in filenames:
                path = os.path.join(dirpath, fn)
                if dropin_dir and fn.endswith(".conf"):
                    units.append(path)
                elif is_unit_name(fn) and not link_dir:
                    defined.add(fn)
                    if not os.path.islink(path):
                        units.append(path)
    return units, defined


def main(argv):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    trees = argv[1:] or [os.path.join(root, "buildroot-external"),
                         os.path.join(root, "buildroot-ihost")]
    for t in trees:
        if not os.path.isdir(t):
            print(f"ERROR: {t} is not a directory", file=sys.stderr)
            return 2

    units, defined = collect(trees)
    unit_files = [u for u in units if not u.endswith(".conf")]
    if not unit_files:
        print("ERROR: found zero unit files in " + " ".join(trees) +
              " — refusing to pass over nothing", file=sys.stderr)
        return 2

    parsed = {u: list(parse(u)) for u in units}
    for u, entries in parsed.items():
        for _, section, key, value in entries:
            if section == "Install" and key == "Alias":
                defined.update(value.split())

    used_base = set()

    def resolves(name):
        if name in defined:
            return True
        if name in BASE_UNITS:
            used_base.add(name)
            return True
        # .device units are synthesised by systemd from udev, not shipped files.
        if name.endswith(".device"):
            return True
        m = re.match(r"^([^@]+@)[^@]+(\.[a-z]+)$", name)
        if not m:
            return False
        template = m.group(1) + m.group(2)
        if template in defined:
            return True
        if template in BASE_UNITS:
            used_base.add(template)
            return True
        return False

    findings = []
    refs = 0
    for u in sorted(parsed):
        rel = os.path.relpath(u, root) if u.startswith(root) else u
        for lineno, section, key, value in parsed[u]:
            if section == "Service" and key in START_LIMIT_KEYS:
                findings.append(f"{rel}:{lineno}: {key}= in [Service] — "
                                f"belongs in [Unit] (StartLimitIntervalSec= is "
                                f"ignored in [Service])")
            if (section == "Unit" and key in UNIT_DEP_KEYS) or \
               (section == "Install" and key in INSTALL_DEP_KEYS):
                for name in value.split():
                    if "%" in name:
                        continue
                    refs += 1
                    if not resolves(name):
                        findings.append(f"{rel}:{lineno}: {key}={name} — no such "
                                        f"unit in the image (not shipped in this "
                                        f"tree, not an Alias=, not in BASE_UNITS)")

    # Only meaningful over the real tree: a fixture references a handful.
    if not argv[1:]:
        for name in sorted(set(BASE_UNITS) - used_base):
            findings.append(f"BASE_UNITS: {name} is referenced by no shipped "
                            f"unit — remove the entry")

    for f in findings:
        print(f)
    print(f"check-unit-refs: {len(unit_files)} unit files + "
          f"{len(units) - len(unit_files)} drop-ins read, {refs} unit references "
          f"checked, {len(findings)} finding(s)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
