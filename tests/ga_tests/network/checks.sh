#!/bin/sh
# Pure helpers for the network suite (sourced by test.sh and selftest.sh).
# No device access: they read the files / strings they are handed.

# nm_effective KEY FILE...  -> value of the LAST active "KEY=value" line.
# NetworkManager merges NetworkManager.conf and conf.d/*.conf in order and the
# last definition wins (later conf.d file overrides the main file), so "is the
# string present in NetworkManager.conf" is the wrong question: since HAOS 18.x
# the GA settings live in conf.d/50-ga.conf and the main file is the unmodified
# upstream one (which even carries its own, overridden, connectivity uri).
nm_effective() {
  _k="$1"; shift
  cat "$@" 2>/dev/null | grep -E "^[[:space:]]*${_k}=" | tail -1 | cut -d= -f2-
}

# ota_prod_slot_required LABEL -> 0 only for a FINAL release label (BOSv1.6.0).
# push-ota.sh stages the prod slot releases/<ver>/haos_ihost-<ver>.raucb for
# releases only; rc/dev builds go to releases/<ver>/<label>/ or nowhere.
# Unknown/empty label -> required (fail closed).
ota_prod_slot_required() {
  case "$1" in
    *-rc[0-9]*|*-dev[0-9]*|*-alpha*|*-beta*|*-pre*) return 1 ;;
    *) return 0 ;;
  esac
}

# ota_not_promoted_reason LABEL PROMOTED_HTTP_CODE — rc 0 (and the skip reason on
# stdout) when the prod slot is not promoted YET: the OTA server ANSWERED 404 for
# PROMOTED.json. Any label: an rc is never promoted, and a FINAL is promoted only
# after its gate (weekly sprint, KB #381: bake -> gate -> sign-off -> tag ->
# promote), so the gate always meets it unpromoted. A skip, never a pass. Every
# other answer (200 = promoted, judged strictly; 000/403/5xx/empty = no answer)
# is rc 1 and the checks run. An empty label is rc 1 (fail closed).
ota_not_promoted_reason() {
  [ -n "$1" ] && [ "$2" = 404 ] || return 1
  if ota_prod_slot_required "$1"; then
    echo "not promoted yet: final $1, PROMOTED.json answers 404 (the prod slot is filled at promotion, after the gate)"
  else
    echo "not promoted: pre-release build ($1), PROMOTED.json answers 404"
  fi
}
