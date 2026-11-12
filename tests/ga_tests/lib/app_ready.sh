#!/bin/sh
# app_ready.sh - suite preflight: wait until the APPS inside the containers answer,
# not only until the containers are Up. Source it; it only defines functions.
# POSIX sh (BusyBox ash on the device).
#
# WHY (BOSv1.5.1-rc4 on K31, 2026-10-13): a container reads "Up" long before the
# app in it listens. InfluxDB answers /ping some seconds after `docker ps` shows
# it, Core's API some minutes after `ha core start`. Suites that run in that gap
# fail for a timing reason, and a check that is red for a timing reason teaches
# people to ignore the colour.
#
# WHAT IT WAITS FOR (only apps whose container is present - an absent add-on is
# addons_running's business, not a reason to block the run):
#   core    container `homeassistant` -> GET /api/ on Core's port answers
#           (401 without a token is an answer; 000 / 5xx are not)
#   influx  container addon_*_ga_influxdbv1 -> /ping answers 200/204 inside it
# BOUNDED: GA_PREFLIGHT_TIMEOUT seconds (default 300), polled every
# GA_PREFLIGHT_INTERVAL seconds (default 5). It FAILS CLOSED: on timeout it
# prints which app never answered and returns 1; the runner aborts, because a
# report over a device whose apps are not up is noise.
#
# Test seams (the selftest drives the live functions through these):
#   GA_APP_PS_CMD    prints container names (default: docker ps --format '{{.Names}}')
#   GA_APP_CORE_CMD  prints Core's /api/ HTTP code (default: curl on 127.0.0.1)
#   GA_APP_INFLUX_CMD prints influx's /ping HTTP code (default: docker exec curl)

_ga_app_ps()   { if [ -n "${GA_APP_PS_CMD:-}" ]; then sh -c "$GA_APP_PS_CMD"; else docker ps --format '{{.Names}}' 2>/dev/null; fi; }

_ga_app_core_code() {
  if [ -n "${GA_APP_CORE_CMD:-}" ]; then sh -c "$GA_APP_CORE_CMD"; return; fi
  _ac_ports=${GA_HA_PORT:-"80 8123"}
  for _ac_p in $_ac_ports; do
    _ac_c=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$_ac_p/api/" 2>/dev/null)
    case "$_ac_c" in 000|'') ;; *) echo "$_ac_c"; return ;; esac
  done
  echo 000
}

_ga_app_influx_code() {
  if [ -n "${GA_APP_INFLUX_CMD:-}" ]; then sh -c "$GA_APP_INFLUX_CMD"; return; fi
  _ai_c=$(_ga_app_ps | grep -E '^addon_.*_ga_influxdbv1$' | head -1)
  [ -n "$_ai_c" ] || { echo 000; return; }
  docker exec "$_ai_c" sh -c 'curl -s -o /dev/null -m 3 -w %{http_code} http://127.0.0.1:8086/ping' 2>/dev/null || echo 000
}

# Is the app answering? 0 = yes.
_ga_app_answers() {
  case "$1" in
    core)   case "$(_ga_app_core_code)" in 200|301|302|303|401|403) return 0 ;; esac ;;
    influx) case "$(_ga_app_influx_code)" in 200|204) return 0 ;; esac ;;
  esac
  return 1
}

# The apps this device runs, from the containers that are present.
_ga_app_expected() {
  _ae_names=$(_ga_app_ps)
  printf '%s\n' "$_ae_names" | grep -qx 'homeassistant' && echo core
  printf '%s\n' "$_ae_names" | grep -qE '^addon_.*_ga_influxdbv1$' && echo influx
  return 0
}

# ga_wait_apps_ready: rc 0 = every present app answers (or no container runtime,
# i.e. nothing to wait for - said out loud); rc 1 = timeout, names on stdout.
ga_wait_apps_ready() {
  _aw_timeout=${GA_PREFLIGHT_TIMEOUT:-300}
  _aw_iv=${GA_PREFLIGHT_INTERVAL:-5}
  case "$_aw_timeout" in ''|*[!0-9]*) _aw_timeout=300 ;; esac
  case "$_aw_iv" in ''|*[!0-9]*|0) _aw_iv=5 ;; esac
  if [ -z "${GA_APP_PS_CMD:-}" ] && ! command -v docker >/dev/null 2>&1; then
    echo "  preflight: no docker on this host - nothing to wait for (emulation / laptop run)"
    return 0
  fi
  _aw_apps=$(_ga_app_expected | tr '\n' ' ')
  if [ -z "${_aw_apps% }" ]; then
    echo "  preflight: no homeassistant / influx container present - nothing to wait for"
    return 0
  fi
  _aw_start=$(date +%s)
  _aw_pending=$_aw_apps
  while :; do
    _aw_still=""
    for _aw_a in $_aw_pending; do
      _ga_app_answers "$_aw_a" || _aw_still="$_aw_still $_aw_a"
    done
    _aw_pending=${_aw_still# }
    if [ -z "$_aw_pending" ]; then
      echo "  preflight: apps answering [${_aw_apps% }] after $(( $(date +%s) - _aw_start )) s"
      return 0
    fi
    if [ $(( $(date +%s) - _aw_start )) -ge "$_aw_timeout" ]; then
      echo "  preflight: FAILED - container up but app not answering after ${_aw_timeout} s: $_aw_pending"
      return 1
    fi
    sleep "$_aw_iv"
  done
}
