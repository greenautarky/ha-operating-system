# shellcheck shell=sh
# ga-data-root.sh — the ONE place that knows where Supervisor keeps add-on data
# on the host. Sourced (POSIX sh / busybox ash), never executed.
#
# Supervisor 2025.11.x (BOSv1.5.x) keeps it under  /mnt/data/supervisor/addons/data/<slug>/
# Supervisor 2026.10+  (BOSv1.6)   renamed it to   /mnt/data/supervisor/apps/data/<slug>/
# (Odoo #1610: on a BOSv1.6.0-rc6 device `addons/` does not exist, so every OS
# file that hard-coded it saw nothing: device label "unknown", Loki user
# "anonymous", no RAUC slot picture, five path units that never fired.)
# An image rolled back to 1.5.x, and any device that has not made the Supervisor
# jump yet, still uses addons/, so both are probed. `apps/data` wins when both
# exist: it is what the newer Supervisor writes to.
#
# A CI gate (tests/gates/data_root) fails if any OS file outside this one names
# `supervisor/addons` or `supervisor/apps` itself. systemd .path units cannot
# call a function: they list BOTH literal paths (the sole sanctioned exception).
#
#   ga_data_root            print the data root; return 1 and say so LOUDLY on
#                           stderr when neither directory exists. Prints nothing
#                           and invents no default in that case.
#   ga_data_root_or_unresolved
#                           for consumers that must keep running when the add-on
#                           data is not there yet (boot before Supervisor created
#                           it): same loud stderr error, but prints a path that
#                           can never exist and returns 0, so the caller's own
#                           "file absent" handling applies.
#
# GA_SUPERVISOR_DIR relocates /mnt/data/supervisor (host tests only; nothing on a
# device sets it).

GA_DATA_ROOT_UNRESOLVED=/nonexistent/ga-supervisor-data-root-unresolved

ga_data_root() {
    _gdr_base="${GA_SUPERVISOR_DIR:-/mnt/data/supervisor}"
    if [ -d "$_gdr_base/apps/data" ]; then
        printf '%s\n' "$_gdr_base/apps/data"
    elif [ -d "$_gdr_base/addons/data" ]; then
        printf '%s\n' "$_gdr_base/addons/data"
    else
        echo "ga-data-root: ERROR: neither $_gdr_base/apps/data nor $_gdr_base/addons/data exists — add-on data directory unresolved" >&2
        return 1
    fi
}

ga_data_root_or_unresolved() {
    ga_data_root || printf '%s\n' "$GA_DATA_ROOT_UNRESOLVED"
}
