#!/bin/sh
# site_config_verdict.sh — is the site config in configuration.yaml what Core RUNS?
#
# Usage:
#   site_config_verdict.sh value  <key> <configuration.yaml>
#       print <key> from the `homeassistant:` block (empty if absent); exit 0
#   site_config_verdict.sh <key>  <configuration.yaml> <core_config.json>
#       <key> is one ga_manager owns: latitude longitude elevation time_zone
#       country unit_system. Prints one line of evidence.
#       exit 0 = Core runs the file's value, 1 = it does not (or could not be
#       asked), 2 = the key is not in the file (nothing to compare — skip)
#   site_config_verdict.sh source <core_config.json>
#       print Core's `config_source`; ALWAYS exit 0 (information, never a verdict)
#
# Pure (sh + jq), so CI drives it over fixtures (selftest.sh next to this file)
# and the device runs the same file.
#
# WHY NOT `config_source`. Until 2026-09-29 HCA-11 asserted
# `config_source == yaml` as "our file is authoritative". It is not that.
# Home Assistant 2026.8.2, homeassistant/core_config.py,
# `async_process_ha_core_config` (~l.374-411): Core loads .storage/core.config,
# then every key present in the YAML `homeassistant:` block overrides the stored
# value and sets `config_source = yaml` — at every start and on
# reload_core_config. `config/core/update` (which ga_manager >= 0.216.0 uses to
# apply config live) sets `config_source = storage` until the next start. So the
# field names the LAST WRITER. It flipped between two identical flashes on a
# canary, and would read red after every correct live update.
#
# What authority actually means is checkable directly: for every key ga_manager
# owns, the value Core is running equals the file's value. That is this script.
#
# Comparison is by VALUE, not by text: the old `grep '"latitude": *52.52'` was a
# prefix match with `.` as a wildcard, so Core running 52.5291 passed a file
# saying 52.52.

cmd="$1"

# The `homeassistant:` block only — a two-space key under another top-level
# mapping is not ours. `[^:]*:` and not `.*:`: the greedy form eats to the LAST
# colon, so `internal_url: "http://kibu.local:8123"` would yield `8123`.
block_value() {  # <key> <file>
  awk '/^homeassistant:/ {b=1; next} b && /^[^[:space:]#]/ {b=0} b' "$2" 2>/dev/null \
    | grep -E "^  $1:" | head -1 \
    | sed -e 's/^[^:]*: *//' -e 's/[[:space:]]\{1,\}#.*$//' -e 's/[[:space:]]*$//' \
    | tr -d "\"'\r"
}

case "$cmd" in
  value)
    block_value "$2" "$3"
    exit 0
    ;;
  source)
    f="$2"
    src=$(jq -r '.config_source // empty' "$f" 2>/dev/null)
    echo "config_source=${src:-<not reported>} — names Core's last writer (YAML at start, config/core/update at runtime), not whether the file is authoritative; HCA-09/10 carry that"
    exit 0
    ;;
esac

key="$cmd"; cfg="$2"; f="$3"

case "$key" in
  latitude|longitude|elevation|time_zone|country|unit_system) ;;
  *) echo "not a key ga_manager owns: '$key'"; exit 1 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "jq not available"; exit 1; }

want=$(block_value "$key" "$cfg")
[ -n "$want" ] || { echo "$key not set in the homeassistant: block"; exit 2; }

# Could not ask Core is a FAIL, never a pass over nothing.
[ -s "$f" ] || { echo "file $key=$want; Core /api/config not read (empty)"; exit 1; }
jq -e 'type == "object"' "$f" >/dev/null 2>&1 \
  || { echo "file $key=$want; Core /api/config is not a JSON object"; exit 1; }

src=$(jq -r '.config_source // "?"' "$f")

case "$key" in
  latitude|longitude|elevation)
    got=$(jq -c --arg k "$key" '.[$k]' "$f")
    r=$(jq -r --arg k "$key" --arg w "$want" '
      (.[$k]) as $c | ($w | tonumber? // null) as $n
      | if $n == null then "badfile"
        elif ($c | type) != "number" then "nocore"
        elif $c == $n then "eq" else "ne" end' "$f")
    echo "file $key=$want; Core runs $key=$got (config_source=$src)"
    case "$r" in
      eq) exit 0 ;;
      badfile) echo "  file value is not a number"; exit 1 ;;
      *) exit 1 ;;
    esac
    ;;
  time_zone|country)
    got=$(jq -r --arg k "$key" '.[$k] // "<absent>"' "$f")
    echo "file $key=$want; Core runs $key=$got (config_source=$src)"
    [ "$got" = "$want" ]
    ;;
  unit_system)
    # Core reports the unit system as a dict of per-measurement units
    # (util/unit_system.py UnitSystem.as_dict), never the name. The name maps to
    # three of them — the ones a resident sees first.
    case "$want" in
      metric) wl=km; wt="°C"; wm=g ;;
      us_customary|imperial) wl=mi; wt="°F"; wm=lb ;;
      *) echo "file unit_system=$want is not metric or us_customary"; exit 1 ;;
    esac
    got=$(jq -r '.unit_system | if type == "object" then "\(.length // "?")/\(.temperature // "?")/\(.mass // "?")" else "<absent>" end' "$f")
    echo "file unit_system=$want ($wl/$wt/$wm); Core runs length/temperature/mass=$got (config_source=$src)"
    [ "$got" = "$wl/$wt/$wm" ]
    ;;
esac
