#!/bin/sh
# room_modes.sh — snapshot every ga_heating room's mode before the heating suite
# writes anything, and give each room back the mode it HAD (not a hard `auto`).
# Sourced by test.sh; BusyBox ash compatible, jq without oniguruma.
#
# Why this exists: ga-heating >= 0.11 (ADR-0021) reads a write straight to a valve
# as a hand on the radiator, so the room goes manual (`heat`) for its cap of 3 h.
# HEAT-09 writes one valve on purpose. Restoring the room once, right after the
# write, was not enough: on a staging canary (2026-10-08) two rooms stood on `heat`
# for 3 h after the suite, and the heating-plan health check fell to 1/3 rooms
# until the cap ran out. A battery valve can report its setpoint SECONDS after the
# restore — a late report that ga_heating again reads as a hand — so the restore
# here is re-checked after a settle period and repeated until the rooms hold.
#
# The component's own API is used, nothing else: `climate.set_hvac_mode` on the
# room entity (ga_heating climate.py async_set_hvac_mode records the decision in
# .storage/ga_heating room_modes; `auto` also clears manual_until). The room's
# observable mode is its entity state (hvac_mode: auto | heat | off).
#
# Only rooms whose mode DIFFERS from the snapshot are written: a press on an
# unchanged room would end a running boost or absence (async_set_hvac_mode ends
# overrides in force), which is a change of its own.
#
# Known limit: the API cannot set manual_until. A room that was ALREADY manual
# before the suite stays manual, but its 3 h cap may have been restarted.
#
# Needs: $GM (ga_manager container), docker, jq. Overrides for the host selftest:
# GA_HEAT_RESTORE_SETTLE_S (default 30), GA_HEAT_RESTORE_ROUNDS (default 4).

HRM_SETTLE_S="${GA_HEAT_RESTORE_SETTLE_S:-30}"
HRM_ROUNDS="${GA_HEAT_RESTORE_ROUNDS:-4}"

# hrm_read — "<room entity> <state>" per ga_heating room entity, from Core NOW.
# A room entity is a climate.* that is not a z2m valve (climate.0x…) and carries
# a `valves` attribute — the same selection as room_entities in test.sh.
hrm_read() {
  [ -n "${GM:-}" ] || return 1
  docker exec "$GM" sh -c \
    'curl -fsS -m 20 -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/core/api/states' 2>/dev/null \
    | jq -r '.[] | select(.entity_id | startswith("climate."))
                 | select(.entity_id | startswith("climate.0x") | not)
                 | select(.attributes.valves != null)
                 | "\(.entity_id) \(.state)"' 2>/dev/null
}

# hrm_snapshot <file> — record every room's mode. Non-zero when Core could not be
# read (the caller decides; an empty snapshot must never read as "nothing to do").
hrm_snapshot() {
  _hrm_tmp="$1.tmp"
  hrm_read > "$_hrm_tmp" || { rm -f "$_hrm_tmp"; return 1; }
  mv "$_hrm_tmp" "$1"
}

# hrm_set_mode <room> <mode> — through ga_heating's own service.
hrm_set_mode() {
  docker exec "$GM" sh -c \
    "curl -fsS -m 20 -X POST -H \"Authorization: Bearer \$SUPERVISOR_TOKEN\" \
          -H 'Content-Type: application/json' \
          -d '{\"entity_id\":\"$1\",\"hvac_mode\":\"$2\"}' \
          http://supervisor/core/api/services/climate/set_hvac_mode" </dev/null >/dev/null 2>&1
}

# hrm_now_of <room> <current file> — the room's current state, or empty.
hrm_now_of() { awk -v e="$1" '$1 == e { print $2; exit }' "$2"; }

# hrm_restore <snapshot> — put every room back to its snapshot mode, then wait,
# re-read and repeat until a full round needs no write (or the rounds run out).
# Prints one line per write. Never fails by itself: hrm_assert is the verdict.
hrm_restore() {
  _snap="$1"; _cur="$_snap.now"
  [ -s "$_snap" ] || return 0
  _round=0
  while [ "$_round" -lt "$HRM_ROUNDS" ]; do
    # Settle FIRST: the report this exists for arrives after the last write.
    sleep "$HRM_SETTLE_S"
    _round=$((_round + 1))
    hrm_read > "$_cur" || : > "$_cur"
    _wrote=0
    while read -r _room _pre; do
      case "$_pre" in auto|heat|off) ;; *) continue ;; esac   # unavailable before: nothing to give back
      _target="$_pre"
      _now=$(hrm_now_of "$_room" "$_cur")
      [ -n "$_now" ] || continue                               # gone: hrm_assert names it
      [ "$_now" = "$_target" ] && continue
      echo "restore round $_round: $_room $_now -> $_target"
      hrm_set_mode "$_room" "$_target" || echo "restore round $_round: set_hvac_mode $_room $_target FAILED"
      _wrote=1
    done < "$_snap"
    [ "$_wrote" -eq 0 ] && break
  done
  rm -f "$_cur"
  return 0
}

# hrm_assert <snapshot> — 0 when every room reads its snapshot mode now; otherwise
# names each room that does not, and returns 1. Reads Core afresh: the verdict is
# taken from the subject, never from what the restore believes it did.
hrm_assert() {
  _snap="$1"; _cur="$_snap.check"
  hrm_read > "$_cur" || { echo "Core /api/states not readable — cannot prove the rooms were given back"; rm -f "$_cur"; return 1; }
  _bad=""; _n=0
  while read -r _room _pre; do
    case "$_pre" in auto|heat|off) ;; *) continue ;; esac
    _n=$((_n + 1))
    _now=$(hrm_now_of "$_room" "$_cur")
    [ "$_now" = "$_pre" ] || _bad="$_bad $_room(before=$_pre now=${_now:-absent})"
  done < "$_snap"
  rm -f "$_cur"
  if [ -n "$_bad" ]; then
    echo "room(s) NOT back in their pre-suite mode:$_bad — a room left on heat is manual for up to 3 h"
    return 1
  fi
  echo "$_n room(s) back in their pre-suite mode: $(awk '{printf "%s%s=%s", (NR>1?", ":""), $1, $2}' "$_snap")"
}
