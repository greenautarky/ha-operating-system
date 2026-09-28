import json
import logging
import os

from labgrid.driver import ShellDriver
import pytest


logger = logging.getLogger(__name__)


@pytest.fixture(scope="function")
def without_internet(strategy):
    default_nic = strategy.qemu.nic
    if strategy.status.name == "shell":
        strategy.transition("off")
    strategy.qemu.nic = "user,net=192.168.76.0/24,dhcpstart=192.168.76.10,restrict=yes"
    strategy.transition("shell")
    yield
    strategy.transition("off")
    strategy.qemu.nic = default_nic


@pytest.fixture(autouse=True, scope="module")
def restart_qemu(strategy):
    """Use fresh QEMU instance for each module."""
    if strategy.status.name == "shell":
        logger.info("Restarting QEMU before %s module tests.", strategy.target.name)
        strategy.transition("off")
        strategy.transition("shell")


@pytest.hookimpl
def pytest_runtest_setup(item):
    log_dir = item.config.option.lg_log

    if not log_dir:
        return

    logging_plugin = item.config.pluginmanager.get_plugin("logging-plugin")
    log_name = item.nodeid.replace(".py::", "/")
    logging_plugin.set_log_path(os.path.join(log_dir, f"{log_name}.log"))


@pytest.fixture
def shell(target, strategy) -> ShellDriver:
    """Fixture for accessing shell."""
    strategy.transition("shell")
    shell = target.get_driver("ShellDriver")
    return shell


@pytest.fixture
def shell_json(target, strategy) -> callable:
    """Fixture for running CLI commands returning JSON string as output."""
    strategy.transition("shell")
    shell = target.get_driver("ShellDriver")

    def get_json_response(command, *, timeout=None) -> dict:
        return json.loads("\n".join(shell.run_check(command, timeout=timeout)))

    return get_json_response


# Home Assistant 2026.8 serves on :80, older Core on :8123 (ADR-0038). Same rule
# as tests/ga_tests/lib/ha_port.sh: the Supervisor's port, else the Core version
# (>= 2026.8 -> 80, older -> 8123), else fail — never a guessed port.
HA_STORAGE_SINCE = (2026, 8)


def resolve_ha_port(core_info: dict) -> int:
    data = (core_info or {}).get("data") or {}
    port = data.get("port")
    if isinstance(port, int) or (isinstance(port, str) and port.isdigit()):
        return int(port)
    version = str(data.get("version") or "")
    parts = version.split(".")
    try:
        major, minor = int(parts[0]), int("".join(c for c in parts[1] if c.isdigit()) or "x")
    except (IndexError, ValueError):
        raise AssertionError(
            f"cannot resolve the Home Assistant port: no port and no parseable Core version ({version!r})"
        ) from None
    return 80 if (major, minor) >= HA_STORAGE_SINCE else 8123


@pytest.fixture
def ha_url(shell):
    """Callable -> ``http://localhost:<port>`` for the Core this image runs.

    Lazy, because a test may first have to wait for Core to exist."""
    def _url() -> str:
        raw = "\n".join(shell.run_check("ha core info --raw-json --no-progress"))
        return f"http://localhost:{resolve_ha_port(json.loads(raw))}"
    return _url
