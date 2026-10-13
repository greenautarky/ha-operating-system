# shellcheck shell=sh
# ga-services-conf.sh — the ONE way a GA script loads ga-services.conf.
# Sourced (`.`), never executed. POSIX sh / BusyBox ash compatible.
#
# The baked /etc/ga-services.conf is the default; the /mnt/data/ga-services.conf
# override is layered ON TOP of it. Keys in the override win, keys it does not
# name fall back to the baked value. The override is therefore allowed to be
# partial (the staging seed writes only the fleet values).
#
# Why a shared helper: three scripts once read the override INSTEAD of the
# default, so a partial override hid every default key (GA_SERVICES_IP, the OTA
# list, ...). #590 fixed those three by hand-copying the layering into each;
# the next consumer written (ga-mesh-watchdog) copied the OLD shape and was
# blind on every device with a partial override. One implementation, one test
# (tests/ga_tests/services_config/layering.sh), no per-script copies.
#
# Usage:
#   . "${GA_SERVICES_CONF_LIB:-/usr/libexec/ga-services-conf.sh}"
#   ga_load_services_conf "$DEFAULT_FILE" "$OVERRIDE_FILE" || <nothing readable>
# Afterwards GA_CONF_LOADED names the files read ("a + b"), "" if none.
# Return 0 when at least one file was loaded, 1 when neither exists.

ga_load_services_conf() {
    GA_CONF_LOADED=""
    if [ -f "$1" ]; then
        # shellcheck disable=SC1090
        . "$1"
        GA_CONF_LOADED="$1"
    fi
    if [ -f "$2" ]; then
        # shellcheck disable=SC1090
        . "$2"
        GA_CONF_LOADED="${GA_CONF_LOADED:+$GA_CONF_LOADED + }$2"
    fi
    [ -n "$GA_CONF_LOADED" ]
}
