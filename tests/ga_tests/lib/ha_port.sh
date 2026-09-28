#!/bin/sh
# ha_port.sh — which TCP port Home Assistant Core serves on, resolved ONCE.
# Source it; it only defines functions. POSIX sh (BusyBox ash on the device,
# bash/dash on a laptop runner).
#
# WHY THIS EXISTS (ADR-0038, 2026-09-28)
# ======================================
# Home Assistant 2026.8 serves on :80 by default; everything older serves on
# :8123. The fleet stays mixed for a long time, so neither number may be
# hard-coded. Before this helper every suite and runner said
# `http://localhost:8123`, and on a device on Core 2026.8.2 that is a closed
# port: the wizard, the password-reset page and the frontend bundle all served
# 200 on :80 while nine checks reported them missing. A check that is red for
# a port reason teaches people to ignore the gate.
#
# THE ORDER (one rule, applied the same way everywhere)
#   1. GA_HA_PORT already set (a runner resolved it, or an operator pinned it)
#      -> use it. That is what "resolved ONCE" means: run_all.sh resolves and
#      exports, every suite inherits.
#   2. The Supervisor's belief, `ha core info --raw-json` .data.port. Measured
#      correct on Core 2026.8.2 (rc54, 2026-09-28).
#   3. No port, but a Core version: >= 2026.8 -> 80, < 2026.8 -> 8123. The
#      default is 80; 8123 only for a device POSITIVELY known to be old.
#   4. Neither port nor version -> FAIL CLOSED with the reason on stderr. A
#      guess here would aim every HTTP check at a port chosen by the helper,
#      and a wrong guess reads as "the product is down".
#
# TRANSPORT. On the device the info comes from `ha core info`. A laptop runner
# sets GA_HA_INFO_CMD to the same command behind its ssh, e.g.
#   GA_HA_INFO_CMD="ssh -p 22222 root@<device> ha core info --raw-json --no-progress"
# Tests set it to `cat <fixture>`.
#
# PUBLIC FUNCTIONS
#   ga_ha_port             -> prints the port; rc 1 + reason on stderr if unresolvable
#   ga_ha_port_explain     -> prints "port=<p> source=<s> core=<v>" (for report headers)
#   ga_ha_url_port <port>  -> "" for 80, ":<port>" otherwise (internal_url form)
#   ga_ha_parse_core_info  -> reads `ha core info --raw-json` on stdin, prints
#                             "<port>|<version>" (either may be empty)
#   ga_ha_port_from_info <port> <version> -> the rule above, pure; prints
#                             "<port> <source>" or returns 1

GA_HA_STORAGE_SINCE_MAJOR=2026
GA_HA_STORAGE_SINCE_MINOR=8

ga_ha_parse_core_info() {
  _hpi_raw=$(cat)
  if command -v jq >/dev/null 2>&1; then
    _hpi_port=$(printf '%s' "$_hpi_raw" | jq -r '.data.port // empty' 2>/dev/null)
    _hpi_ver=$(printf '%s' "$_hpi_raw" | jq -r '.data.version // empty' 2>/dev/null)
  else
    # One-line JSON from the CLI. `"port":` and `"version":"` are unique in
    # core info (the other key is version_latest, which the quote excludes).
    _hpi_port=$(printf '%s' "$_hpi_raw" | tr ',' '\n' | sed -n 's/.*"port": *\([0-9][0-9]*\).*/\1/p' | head -1)
    _hpi_ver=$(printf '%s' "$_hpi_raw" | tr ',' '\n' | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' | head -1)
  fi
  case "$_hpi_port" in ''|*[!0-9]*) _hpi_port="" ;; esac
  [ "$_hpi_ver" = "null" ] && _hpi_ver=""
  printf '%s|%s\n' "$_hpi_port" "$_hpi_ver"
}

# rc 0 = known >= 2026.8, rc 1 = known older, rc 2 = unparseable.
ga_ha_core_is_storage_era() {
  # "2026.8.2" / "2026.10.0b1" / "2025.11.5" -> major, minor. Anything else
  # (empty, "landingpage", "null") is unparseable, never "old".
  _hv_maj=$(printf '%s' "$1" | cut -d. -f1)
  _hv_min=$(printf '%s' "$1" | cut -s -d. -f2 | sed 's/[^0-9].*//')
  case "$_hv_maj" in [0-9][0-9][0-9][0-9]) ;; *) return 2 ;; esac
  case "$_hv_min" in ''|*[!0-9]*) return 2 ;; esac
  if [ "$_hv_maj" -gt "$GA_HA_STORAGE_SINCE_MAJOR" ]; then return 0; fi
  if [ "$_hv_maj" -lt "$GA_HA_STORAGE_SINCE_MAJOR" ]; then return 1; fi
  [ "$_hv_min" -ge "$GA_HA_STORAGE_SINCE_MINOR" ]
}

ga_ha_port_from_info() {
  _hf_port="$1"; _hf_ver="$2"
  if [ -n "$_hf_port" ]; then
    printf '%s supervisor\n' "$_hf_port"; return 0
  fi
  _hf_era=0
  ga_ha_core_is_storage_era "$_hf_ver" || _hf_era=$?   # safe under set -e
  case $_hf_era in
    0) printf '80 default-for-core-%s\n' "$_hf_ver"; return 0 ;;
    1) printf '8123 known-old-core-%s\n' "$_hf_ver"; return 0 ;;
  esac
  echo "ha_port: cannot resolve the Home Assistant port — Supervisor reported no port and no parseable Core version (version=${_hf_ver:-none}). Refusing to guess between 80 and 8123." >&2
  return 1
}

# Resolve once, cache in GA_HA_PORT / GA_HA_PORT_SOURCE / GA_HA_CORE_VERSION
# (exported so child suites inherit).
_ga_ha_port_resolve() {
  if [ -n "${GA_HA_PORT:-}" ]; then
    case "$GA_HA_PORT" in
      *[!0-9]*) echo "ha_port: GA_HA_PORT=$GA_HA_PORT is not a port number" >&2; return 1 ;;
    esac
    GA_HA_PORT_SOURCE="${GA_HA_PORT_SOURCE:-preset}"
    export GA_HA_PORT GA_HA_PORT_SOURCE
    return 0
  fi
  _hr_cmd="${GA_HA_INFO_CMD:-ha core info --raw-json --no-progress}"
  _hr_pv=$(eval "$_hr_cmd" 2>/dev/null | ga_ha_parse_core_info)
  _hr_res=$(ga_ha_port_from_info "${_hr_pv%%|*}" "${_hr_pv#*|}") || return 1
  GA_HA_PORT="${_hr_res%% *}"
  GA_HA_PORT_SOURCE="${_hr_res#* }"
  GA_HA_CORE_VERSION="${_hr_pv#*|}"
  export GA_HA_PORT GA_HA_PORT_SOURCE GA_HA_CORE_VERSION
}

ga_ha_port() {
  _ga_ha_port_resolve || return 1
  printf '%s\n' "$GA_HA_PORT"
}

ga_ha_port_explain() {
  if _ga_ha_port_resolve 2>/dev/null; then
    printf 'port=%s source=%s core=%s\n' "$GA_HA_PORT" "$GA_HA_PORT_SOURCE" "${GA_HA_CORE_VERSION:-?}"
  else
    printf 'port=UNRESOLVED\n'
  fi
}

ga_ha_url_port() {
  if [ "$1" = "80" ]; then printf ''; else printf ':%s' "$1"; fi
}
