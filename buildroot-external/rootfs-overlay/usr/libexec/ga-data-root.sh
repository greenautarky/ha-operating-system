# shellcheck shell=sh
# ga-data-root.sh — the ONE place that knows where Supervisor keeps add-on data
# on the host. Sourced (POSIX sh / busybox ash), never executed.
#
# Supervisor 2025.11.x (BOSv1.5.x) keeps it under  /mnt/data/supervisor/addons/data/<slug>/
# Supervisor 2026.10+  (BOSv1.6)   renamed it to   /mnt/data/supervisor/apps/data/<slug>/
# (Odoo #1610: on a BOSv1.6.0-rc6 device `addons/` does not exist, so every OS
# file that hard-coded it saw nothing: device label "unknown", Loki user
# "anonymous", no RAUC slot picture, five path units that never fired.)
# Both trees can exist at once, and the one that LINGERS is the wrong one:
#   - Supervisor 2026.10 migrates addons/data -> apps/data only if apps/data does
#     not exist yet (supervisor/bootstrap.py _migrate_legacy_paths, fork branch
#     ga/2026.10.5-wp9-3: `if old.is_dir() and not new.exists(): old.rename(new)`),
#     and it creates an empty apps/data itself at start. So a device that was
#     rolled back 1.6 -> 1.5.x has a stale apps/data next to the live addons/data,
#     and one upgraded again afterwards has a stale addons/data.
# So the choice follows the Supervisor that is RUNNING, not which directory exists:
#   1. discriminator: the version label of the running hassio_supervisor container,
#      `docker inspect -f '{{index .Config.Labels "io.hass.version"}}'`
#      (e.g. 2025.11.5.4 / 2026.10.5.x). >= 2026.10 -> apps/data, below -> addons/data.
#      Read on every call (no cache: a cache could outlive a Supervisor change).
#   2. Supervisor not running / unreadable: a tree only counts if it holds the
#      pinned ga_manager slug dir (*_ga_manager). One qualifies -> it. Both ->
#      the one whose slug dir has the newest mtime. Equal mtimes, or none
#      qualifies -> LOUD ERROR, nothing printed.
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

# _gdr_supervisor_year_month — print "YYYYMM" of the running Supervisor (empty when
# the container is not running or the label is unreadable).
_gdr_supervisor_ym() {
    if command -v timeout >/dev/null 2>&1; then _gdr_to_cmd="timeout 10"; else _gdr_to_cmd=; fi
    _gdr_v="$($_gdr_to_cmd docker inspect -f '{{index .Config.Labels "io.hass.version"}}' hassio_supervisor 2>/dev/null)" || return 0
    case "$_gdr_v" in
        [0-9][0-9][0-9][0-9].[0-9]*)
            _gdr_y="${_gdr_v%%.*}"; _gdr_r="${_gdr_v#*.}"; _gdr_m="${_gdr_r%%.*}"
            case "$_gdr_m" in ''|*[!0-9]*) return 0 ;; esac
            printf '%s%02d\n' "$_gdr_y" "$_gdr_m" ;;
    esac
}

# _gdr_slug_mtime <tree> — newest mtime of a *_ga_manager dir directly under <tree>; empty if none.
_gdr_slug_mtime() {
    _gdr_best=
    for _gdr_d in "$1"/*_ga_manager; do
        [ -d "$_gdr_d" ] || continue
        _gdr_t="$(stat -c %Y "$_gdr_d" 2>/dev/null)" || continue
        if [ -z "$_gdr_best" ] || [ "$_gdr_t" -gt "$_gdr_best" ]; then _gdr_best="$_gdr_t"; fi
    done
    printf '%s' "$_gdr_best"
}

ga_data_root() {
    _gdr_base="${GA_SUPERVISOR_DIR:-/mnt/data/supervisor}"
    _gdr_ym="$(_gdr_supervisor_ym)"
    if [ -n "$_gdr_ym" ]; then
        if [ "$_gdr_ym" -ge 202610 ]; then _gdr_sub=apps; else _gdr_sub=addons; fi
        if [ -d "$_gdr_base/$_gdr_sub/data" ]; then
            printf '%s\n' "$_gdr_base/$_gdr_sub/data"
            return 0
        fi
        echo "ga-data-root: ERROR: running Supervisor ($_gdr_ym) uses $_gdr_base/$_gdr_sub/data, which does not exist — add-on data directory unresolved" >&2
        return 1
    fi
    _gdr_ta="$(_gdr_slug_mtime "$_gdr_base/apps/data")"
    _gdr_to="$(_gdr_slug_mtime "$_gdr_base/addons/data")"
    if [ -n "$_gdr_ta" ] && [ -z "$_gdr_to" ]; then
        printf '%s\n' "$_gdr_base/apps/data"; return 0
    elif [ -z "$_gdr_ta" ] && [ -n "$_gdr_to" ]; then
        printf '%s\n' "$_gdr_base/addons/data"; return 0
    elif [ -n "$_gdr_ta" ] && [ -n "$_gdr_to" ]; then
        if [ "$_gdr_ta" -gt "$_gdr_to" ]; then printf '%s\n' "$_gdr_base/apps/data"; return 0; fi
        if [ "$_gdr_to" -gt "$_gdr_ta" ]; then printf '%s\n' "$_gdr_base/addons/data"; return 0; fi
        echo "ga-data-root: ERROR: Supervisor not running and $_gdr_base/apps/data and $_gdr_base/addons/data both hold a ga_manager dir with the same mtime — cannot tell which is live" >&2
        return 1
    fi
    echo "ga-data-root: ERROR: Supervisor not running and neither $_gdr_base/apps/data nor $_gdr_base/addons/data holds a *_ga_manager dir — add-on data directory unresolved" >&2
    return 1
}

ga_data_root_or_unresolved() {
    ga_data_root || printf '%s\n' "$GA_DATA_ROOT_UNRESOLVED"
}
