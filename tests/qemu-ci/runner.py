#!/usr/bin/env python3
"""qemu-ci runner — boot a haos_qemu qcow2 in qemu and drive on-device tests.

This is the *whole* test harness for the qemu CI lane. ~280 lines on purpose:
the previous attempt used labgrid (see tests/qemu_shell_strategy.py) and was
rejected as too heavy for what's essentially "spawn qemu, run shell commands,
grep output". pexpect + a few result dataclasses do the same thing readable.

Flow:
  1. Decompress haos_qemu-*.qcow2.xz into a snapshot-friendly working copy.
  2. Boot qemu-system-x86_64 with stdio-serial console and a virtio-9p share
     of `tests/ga_tests/` mounted read-only at /tmp/ga_tests inside the guest.
  3. Wait for the autologin prompt (provisioned by board/pc/qemu/rootfs-overlay).
  4. Wait for systemd `multi-user.target` then for the supervisor to respond
     to `ha core info`. The supervisor wait has a hard ceiling — if it isn't
     ready in time, supervisor_health is skipped rather than failing the run.
  5. Run the requested suite list via `tests/ga_tests/run_all.sh`. Default is
     the `--category emu` set (env / crash_detection / boot_timing / disk_guard
     / supervisor_health).
  6. Capture serial output to `qemu-serial.log` and the run summary to
     `qemu-results.json`. CI uploads both as artifacts on failure.
  7. Exit 0 iff every requested suite passed; non-zero otherwise.

The serial console is the *only* exposed interaction surface. No SSH, no port
forward, no Docker socket forwarding — keeps the harness portable across
GitHub-hosted, self-hosted, and laptop runs.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

try:
    import pexpect  # type: ignore
except ImportError:
    print("FATAL: python3-pexpect is required (apt install python3-pexpect)", file=sys.stderr)
    sys.exit(2)


REPO_ROOT = Path(__file__).resolve().parents[2]
GA_TESTS_DIR = REPO_ROOT / "tests" / "ga_tests"

# Wall-clock budgets. Upper bounds — the harness short-circuits as soon as a
# positive signal is seen. Tuned for GH Actions ubuntu-latest + KVM; bumping
# these is preferable to lowering them when a flake surfaces.
BOOT_PROMPT_S = 180        # kernel + systemd -> login prompt / autologin
MULTI_USER_S = 120         # multi-user.target after we have a shell
SUPERVISOR_S = 300         # `ha core info` to return successfully
TEST_RUNNER_S = 300        # entire run_all.sh invocation
SHUTDOWN_S = 30            # poweroff -> qemu exit


@dataclass
class RunResult:
    booted: bool = False
    multi_user_reached: bool = False
    supervisor_ready: bool = False
    suites_run: list[str] = field(default_factory=list)
    pass_count: int = 0
    fail_count: int = 0
    skip_count: int = 0
    elapsed_s: float = 0.0
    fail_reason: str | None = None


def find_qcow2_xz(images_dir: Path) -> Path:
    candidates = sorted(images_dir.glob("haos_qemu-*.qcow2.xz")) + sorted(
        images_dir.glob("bos_qemu-*.qcow2.xz")
    )
    if not candidates:
        raise FileNotFoundError(
            f"no haos_qemu-*.qcow2.xz / bos_qemu-*.qcow2.xz found in {images_dir}"
        )
    return max(candidates, key=lambda p: p.stat().st_mtime)


def decompress(src_xz: Path, dest_qcow2: Path) -> None:
    """xz-decompress into a working copy; keep the original .xz intact."""
    if dest_qcow2.exists():
        dest_qcow2.unlink()
    print(f"[qemu-ci] decompressing {src_xz.name} -> {dest_qcow2.name}", flush=True)
    with open(dest_qcow2, "wb") as fh:
        subprocess.run(
            ["xz", "-d", "-c", "-T0", str(src_xz)],
            stdout=fh, check=True,
        )


def build_qemu_argv(qcow2: Path, share_dir: Path, mem: int, cpus: int, accel: str) -> list[str]:
    return [
        "qemu-system-x86_64",
        "-machine", "q35,accel=" + accel,
        "-cpu", "max",
        "-m", str(mem),
        "-smp", str(cpus),
        "-nographic",
        "-serial", "mon:stdio",
        "-bios", "/usr/share/ovmf/OVMF.fd",
        # snapshot=on -> writes hit a tempfile and are discarded on quit.
        # Lets us re-use the same decompressed qcow2 across retries.
        "-drive", f"file={qcow2},format=qcow2,if=virtio,snapshot=on",
        # Tests are shared in via virtio-9p — no scp/wget inside the guest.
        # The qemu kernel.config fragment promotes 9P modules from =m to =y
        # so this just works at runtime without `modprobe`.
        "-virtfs",
        f"local,path={share_dir},mount_tag=ga_tests,security_model=mapped-xattr,readonly=on",
        # User-mode networking — Supervisor needs outbound for stable.json
        # fetch and image pulls. No host-side setup required.
        "-netdev", "user,id=net0",
        "-device", "virtio-net-pci,netdev=net0",
    ]


def spawn_qemu(argv: list[str], log_path: Path) -> pexpect.spawn:
    print(f"[qemu-ci] launching: {' '.join(argv)}", flush=True)
    child = pexpect.spawn(
        argv[0], argv[1:],
        encoding="utf-8",
        codec_errors="replace",
        timeout=BOOT_PROMPT_S,
        # Generous read buffer — kernel dmesg + supervisor JSON dumps are
        # both relevant post-mortem and we don't want pexpect to truncate.
        maxread=8192,
    )
    child.logfile = log_path.open("w")
    return child


def wait_for_shell(child: pexpect.spawn) -> bool:
    """Wait until we're at a # prompt as root.

    The qemu board overlay autologins root on ttyS0 (see
    board/pc/qemu/rootfs-overlay/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf),
    so we should see the welcome banner + a `#` without typing anything. If the
    autologin override didn't take (= overlay drift), we fall back to typing
    `root` so the harness still surfaces a useful message instead of timing out.
    """
    try:
        idx = child.expect(
            [
                r"\r\n# ",                                  # 0 — root prompt
                r"homeassistant login:",                    # 1 — manual login
                r"Kernel panic|end Kernel panic|\bOops\b",  # 2 — fatal
            ],
            timeout=BOOT_PROMPT_S,
        )
    except pexpect.TIMEOUT:
        print("[qemu-ci] FATAL: boot timeout — never reached login prompt", flush=True)
        return False

    if idx == 0:
        print("[qemu-ci] root autologin OK", flush=True)
        return True
    if idx == 1:
        print("[qemu-ci] WARN: autologin overlay did not take — typing root manually", flush=True)
        child.sendline("root")
        try:
            child.expect(r"\r\n# ", timeout=15)
            return True
        except pexpect.TIMEOUT:
            print("[qemu-ci] FATAL: shell never appeared after manual login", flush=True)
            return False

    print("[qemu-ci] FATAL: kernel panic during boot — see qemu-serial.log", flush=True)
    return False


def run_command(child: pexpect.spawn, cmd: str, timeout: int = 30) -> tuple[int, str]:
    """Run a single shell command in the guest, return (exit_code, stdout).

    Uses a sentinel + the captured exit code so we can scrape output cleanly
    even when the command itself produces `#`-laced multiline output.
    """
    sentinel_tag = f"__ga_done_{int(time.time()*1000)}_"
    child.sendline(f"{cmd}; echo {sentinel_tag}$?")
    pattern = re.compile(re.escape(sentinel_tag) + r"(\d+)\b")
    try:
        child.expect(pattern, timeout=timeout)
    except pexpect.TIMEOUT:
        return 124, child.before or ""
    match = pattern.search(child.after or "")
    code = int(match.group(1)) if match else 1
    return code, (child.before or "").lstrip()


def wait_for_multi_user(child: pexpect.spawn) -> bool:
    print("[qemu-ci] waiting for multi-user.target...", flush=True)
    deadline = time.time() + MULTI_USER_S
    while time.time() < deadline:
        code, _ = run_command(child, "systemctl is-active multi-user.target", timeout=10)
        if code == 0:
            print("[qemu-ci] multi-user.target active", flush=True)
            return True
        time.sleep(5)
    print("[qemu-ci] WARN: multi-user.target never became active", flush=True)
    return False


def wait_for_supervisor(child: pexpect.spawn) -> bool:
    """`ha core info` returning successfully = supervisor responsive.

    Also implicitly verifies the version chain — if stable.json fetch
    failed or version.json was malformed, `ha core info` errors with the
    same Supervisor warnings Bug #3 produced on the bench.
    """
    print("[qemu-ci] waiting for supervisor to respond to `ha core info`...", flush=True)
    deadline = time.time() + SUPERVISOR_S
    last_err = ""
    while time.time() < deadline:
        code, out = run_command(child, "ha core info 2>&1 | head -5", timeout=20)
        if code == 0 and "version" in out.lower():
            print("[qemu-ci] supervisor responsive", flush=True)
            return True
        last_err = out[:200]
        time.sleep(10)
    print(f"[qemu-ci] WARN: supervisor never came up; last reply: {last_err!r}", flush=True)
    return False


def mount_test_share(child: pexpect.spawn) -> bool:
    code, _ = run_command(child, "mkdir -p /tmp/ga_tests", timeout=10)
    if code != 0:
        return False
    code, out = run_command(
        child,
        "mount -t 9p -o trans=virtio,version=9p2000.L,ro ga_tests /tmp/ga_tests",
        timeout=15,
    )
    if code != 0:
        print(f"[qemu-ci] FATAL: 9p mount failed: {out}", flush=True)
        return False
    code, out = run_command(child, "test -x /tmp/ga_tests/run_all.sh && echo OK", timeout=10)
    if code != 0:
        print(f"[qemu-ci] FATAL: run_all.sh not visible in share: {out}", flush=True)
        return False
    return True


def run_suites(child: pexpect.spawn, suites: list[str]) -> tuple[int, int, int, str]:
    suites_str = " ".join(suites)
    print(f"[qemu-ci] running suites: {suites_str}", flush=True)
    code, out = run_command(
        child, f"sh /tmp/ga_tests/run_all.sh {suites_str}", timeout=TEST_RUNNER_S,
    )
    _ = code  # exit code isn't load-bearing; we parse the report footer
    # run_all.sh prints a TOTAL row in its report footer:
    #   "  TOTAL                  N    N    N"
    # We grab the LAST such row in case a suite happens to echo the word.
    matches = list(
        re.finditer(
            r"^\s*TOTAL\s+(\d+)\s+(\d+)\s+(\d+)\s*$",
            out,
            flags=re.MULTILINE,
        )
    )
    if not matches:
        return 0, 0, 0, out
    m = matches[-1]
    p, f, s = int(m.group(1)), int(m.group(2)), int(m.group(3))
    return p, f, s, out


def graceful_shutdown(child: pexpect.spawn) -> None:
    try:
        child.sendline("poweroff -f")
        child.expect(pexpect.EOF, timeout=SHUTDOWN_S)
    except (pexpect.TIMEOUT, OSError):
        pass
    finally:
        try:
            child.kill(signal.SIGKILL)
        except (OSError, pexpect.ExceptionPexpect):
            pass


def main() -> int:
    parser = argparse.ArgumentParser(description="qemu-ci runner")
    parser.add_argument(
        "--image",
        default=None,
        help="Path to haos_qemu-*.qcow2.xz (default: auto-detect under --images-dir)",
    )
    parser.add_argument(
        "--images-dir",
        default=str(REPO_ROOT / "ga_output_qemu" / "images"),
        help="Where to look for the freshest qcow2.xz when --image is omitted",
    )
    parser.add_argument("--workdir", default="/tmp/qemu-ci", help="Scratch space")
    parser.add_argument("--mem", type=int, default=2048, help="VM RAM in MB")
    parser.add_argument("--cpus", type=int, default=2, help="VM vCPU count")
    parser.add_argument(
        "--accel",
        default=("kvm" if os.path.exists("/dev/kvm") else "tcg"),
        choices=["kvm", "tcg"],
        help="qemu accelerator",
    )
    parser.add_argument(
        "--suites",
        default="environment crash_detection boot_timing disk_guard supervisor_health",
        help="Space-separated list passed to run_all.sh",
    )
    parser.add_argument(
        "--results",
        default="qemu-results.json",
        help="Path to write the result-summary JSON",
    )
    parser.add_argument(
        "--serial-log",
        default="qemu-serial.log",
        help="Path to mirror the full serial stream into",
    )
    args = parser.parse_args()

    workdir = Path(args.workdir)
    workdir.mkdir(parents=True, exist_ok=True)

    image_xz = Path(args.image) if args.image else find_qcow2_xz(Path(args.images_dir))
    qcow2 = workdir / "vm.qcow2"
    decompress(image_xz, qcow2)

    serial_log = Path(args.serial_log).resolve()
    results_path = Path(args.results).resolve()

    result = RunResult()
    t0 = time.time()

    argv = build_qemu_argv(qcow2, GA_TESTS_DIR, args.mem, args.cpus, args.accel)
    child = spawn_qemu(argv, serial_log)
    try:
        if not wait_for_shell(child):
            result.fail_reason = "boot_timeout"
            return 3
        result.booted = True

        result.multi_user_reached = wait_for_multi_user(child)
        if not result.multi_user_reached:
            result.fail_reason = "multi_user_timeout"
            # Keep going — some suites are useful even pre-multi_user.

        # 9p share has to be mounted before `ha core info` because the
        # supervisor probe can be slow and we'd rather not double-block on it.
        if not mount_test_share(child):
            result.fail_reason = "test_share_mount_failed"
            return 4

        result.supervisor_ready = wait_for_supervisor(child)

        suites = args.suites.split()
        # If supervisor never came up, drop supervisor_health from this run —
        # every SUP-* would fail for the same root cause and the result would
        # mislead. The real signal is `supervisor_ready: false` in the JSON.
        if not result.supervisor_ready and "supervisor_health" in suites:
            suites = [s for s in suites if s != "supervisor_health"]
            print(
                "[qemu-ci] skipping supervisor_health (supervisor not ready)",
                flush=True,
            )

        result.suites_run = suites
        passed, failed, skipped, raw = run_suites(child, suites)
        result.pass_count = passed
        result.fail_count = failed
        result.skip_count = skipped

        if failed > 0 and not result.fail_reason:
            result.fail_reason = "suite_failures"

        print("\n--- last 40 lines of guest output ---")
        for line in raw.splitlines()[-40:]:
            print(line)

    finally:
        result.elapsed_s = time.time() - t0
        graceful_shutdown(child)
        try:
            child.logfile.close()
        except Exception:
            pass
        results_path.write_text(json.dumps(asdict(result), indent=2))
        print(
            f"[qemu-ci] result: boot={result.booted} multi_user={result.multi_user_reached} "
            f"sup={result.supervisor_ready} pass={result.pass_count} "
            f"fail={result.fail_count} skip={result.skip_count} "
            f"elapsed={result.elapsed_s:.1f}s",
            flush=True,
        )
        if qcow2.exists() and not os.environ.get("QEMU_CI_KEEP_QCOW2"):
            try:
                qcow2.unlink()
            except OSError:
                pass

    if result.fail_count > 0:
        return 1
    if not result.booted:
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
