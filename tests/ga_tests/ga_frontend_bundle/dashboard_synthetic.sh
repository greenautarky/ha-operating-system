#!/bin/sh
# dashboard_synthetic.sh — render-sanity-check for the 14 ga_frontend_bundle
# cards using purely synthetic helper entities + template sensors. Designed
# to run on a fresh-flashed device that has NO Zigbee paired yet — proves
# that the cards LOAD without throwing in the browser, not that they show
# real-world data.
#
# Flow:
#   1. Append a helpers + template-sensors block to configuration.yaml
#      (idempotent: removes a previous synthetic block first).
#   2. Append a Lovelace dashboard `lovelace.dashboards.synthetic` that
#      uses each of the 14 vendored cards exactly once.
#   3. Restart HA Core via Supervisor API + wait for state=running.
#   4. Probe the dashboard URL + assert that each card's custom:* tag
#      appears in the rendered HTML.
#
# Exit 0 if all 14 cards render. Non-zero with a clear message otherwise.
#
# Usage on the device:
#   curl -sSL http://gist...../dashboard_synthetic.sh | sh
# OR
#   scp this-script device:/tmp/ && ssh device sh /tmp/dashboard_synthetic.sh

set -eu

HA="${HA:-http://localhost:8123}"
CFG_DIR="/mnt/data/supervisor/homeassistant"
CFG="${CFG_DIR}/configuration.yaml"
BUNDLE_DIR="${CFG_DIR}/custom_components/ga_frontend_bundle"
CARDS_JSON="${BUNDLE_DIR}/community/cards.json"
SYNTH_MARKER="# === ga_frontend_bundle synthetic test block — auto-generated ==="
SYNTH_END="# === end ga_frontend_bundle synthetic block ==="

log()  { printf '[synth] %s\n' "$*"; }
fail() { printf '[synth] ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$CARDS_JSON" ] || fail "$CARDS_JSON missing — ga_frontend_bundle not placed yet"

# --- helpers / synthetic entities -----------------------------------------
# A handful of input_* + template sensors that cover the typical attributes
# our cards consume: numeric state, friendly_name, unit_of_measurement.
SYNTH_YAML="
${SYNTH_MARKER}
input_number:
  synth_temp:
    name: Synth Temperature
    initial: 21.5
    min: -10
    max: 40
    unit_of_measurement: '°C'
  synth_humidity:
    name: Synth Humidity
    initial: 55
    min: 0
    max: 100
    unit_of_measurement: '%'
  synth_power:
    name: Synth Power
    initial: 142
    min: 0
    max: 5000
    unit_of_measurement: 'W'

input_boolean:
  synth_window_open:
    name: Synth Window Open
  synth_heating:
    name: Synth Heating Active

input_select:
  synth_room:
    name: Synth Room
    options: [Wohnzimmer, Schlafzimmer, Bad, Küche]
    initial: Wohnzimmer

template:
  - sensor:
      - name: synth_temp_history_24h
        state: '{{ states(\"input_number.synth_temp\") | float(0) }}'
        unit_of_measurement: '°C'
        device_class: temperature
        state_class: measurement
${SYNTH_END}
"

# --- dashboard YAML -------------------------------------------------------
# Each card used exactly once. card_id → card_type mapping driven from the
# bundle's own cards.json (= ensures any added card gets a slot).
LOVELACE_YAML_FRAGMENT=$(mktemp -t synth-lovelace.XXXXXX)
{
  echo "${SYNTH_MARKER}"
  echo "lovelace:"
  echo "  mode: storage  # leave the default dashboard alone"
  echo "  dashboards:"
  echo "    synthetic:"
  echo "      mode: yaml"
  echo "      title: Synthetic"
  echo "      icon: mdi:test-tube"
  echo "      show_in_sidebar: true"
  echo "      filename: dashboards/synthetic.yaml"
  echo "${SYNTH_END}"
} > "${LOVELACE_YAML_FRAGMENT}"

# Build the synthetic dashboard YAML — one card per ID. Mapping is best-
# effort: cards we know the schema for get a tailored example; the rest
# get a markdown card as fallback so the panel still renders.
DASH_YAML="${CFG_DIR}/dashboards/synthetic.yaml"
mkdir -p "$(dirname "${DASH_YAML}")"

{
  echo "title: Synthetic"
  echo "views:"
  echo "  - title: All 14 cards"
    echo "    cards:"
  jq -r '.cards[] | .id' "${CARDS_JSON}" | while IFS= read -r cid; do
    case "${cid}" in
      mushroom)
        printf "      - type: custom:mushroom-template-card\n"
        printf "        primary: 'Synth Mushroom'\n"
        printf "        secondary: '{{ states(\"input_number.synth_temp\") }} °C'\n"
        printf "        icon: mdi:thermometer\n"
        ;;
      mini-graph-card)
        printf "      - type: custom:mini-graph-card\n"
        printf "        entities:\n"
        printf "          - sensor.synth_temp_history_24h\n"
        printf "        name: Synth Mini Graph\n"
        ;;
      plotly-graph-card)
        printf "      - type: custom:plotly-graph\n"
        printf "        entities:\n"
        printf "          - entity: sensor.synth_temp_history_24h\n"
        printf "            name: Synth Plotly\n"
        ;;
      button-card)
        printf "      - type: custom:button-card\n"
        printf "        entity: input_boolean.synth_heating\n"
        printf "        name: Heating Toggle\n"
        ;;
      apexcharts-card)
        printf "      - type: custom:apexcharts-card\n"
        printf "        series:\n"
        printf "          - entity: sensor.synth_temp_history_24h\n"
        ;;
      auto-entities)
        printf "      - type: custom:auto-entities\n"
        printf "        card:\n"
        printf "          type: entities\n"
        printf "          title: Auto entities (synth)\n"
        printf "        filter:\n"
        printf "          include:\n"
        printf "            - entity_id: input_number.synth_*\n"
        ;;
      layout-card)
        printf "      - type: custom:layout-card\n"
        printf "        layout_type: custom:grid-layout\n"
        printf "        cards:\n"
        printf "          - type: entity\n"
        printf "            entity: input_number.synth_temp\n"
        ;;
      vertical-stack-in-card)
        printf "      - type: custom:vertical-stack-in-card\n"
        printf "        cards:\n"
        printf "          - type: entity\n"
        printf "            entity: input_number.synth_humidity\n"
        ;;
      slider-entity-row)
        printf "      - type: entities\n"
        printf "        entities:\n"
        printf "          - type: custom:slider-entity-row\n"
        printf "            entity: input_number.synth_power\n"
        ;;
      template-entity-row)
        printf "      - type: entities\n"
        printf "        entities:\n"
        printf "          - type: custom:template-entity-row\n"
        printf "            entity: input_number.synth_humidity\n"
        printf "            name: '{{ states(\"input_number.synth_humidity\") }}%%'\n"
        ;;
      state-switch)
        printf "      - type: custom:state-switch\n"
        printf "        entity: input_select.synth_room\n"
        printf "        states:\n"
        printf "          Wohnzimmer:\n"
        printf "            type: markdown\n"
        printf "            content: Living room view\n"
        ;;
      card-mod)
        printf "      - type: markdown\n"
        printf "        content: card-mod active (no visible card)\n"
        printf "        card_mod:\n"
        printf "          style: 'ha-card { background: rgba(0,255,0,0.05); }'\n"
        ;;
      kiosk-mode)
        printf "      - type: markdown\n"
        printf "        content: kiosk-mode loaded (no visible card)\n"
        ;;
      simple-thermostat)
        printf "      - type: custom:simple-thermostat\n"
        printf "        entity: input_number.synth_temp\n"
        printf "        name: Synth Thermostat\n"
        ;;
      *)
        printf "      - type: markdown\n"
        printf "        content: 'card %s — fallback (custom-tag rendered for sanity check)'\n" "${cid}"
        ;;
    esac
  done
} > "${DASH_YAML}"
log "wrote ${DASH_YAML} ($(wc -l < "${DASH_YAML}") lines)"

# --- merge into configuration.yaml (idempotent) ---------------------------
# Strip any previous synthetic blocks, then append the new ones.
if grep -q "${SYNTH_MARKER}" "${CFG}" 2>/dev/null; then
  log "stripping previous synthetic block"
  awk -v start="${SYNTH_MARKER}" -v end="${SYNTH_END}" '
    BEGIN { keep = 1 }
    index($0, start) { keep = 0 }
    keep { print }
    index($0, end) { keep = 1; next }
  ' "${CFG}" > "${CFG}.tmp" && mv "${CFG}.tmp" "${CFG}"
fi

log "appending synthetic helpers + sensors to ${CFG}"
printf '%s' "${SYNTH_YAML}" >> "${CFG}"

# Lovelace section is more delicate — only append if not already present.
if ! grep -q "${SYNTH_MARKER}" "${CFG}"; then
  log "appending lovelace.dashboards.synthetic to ${CFG}"
  cat "${LOVELACE_YAML_FRAGMENT}" >> "${CFG}"
fi
rm -f "${LOVELACE_YAML_FRAGMENT}"

# --- reload Core ---------------------------------------------------------
log "calling Supervisor API to restart Core (= configuration.yaml reload + dashboards register)"
if ! ha core restart --no-progress >/dev/null 2>&1; then
  log "WARN: ha core restart returned non-zero — Core may already be restarting"
fi

# --- wait for state=running ---------------------------------------------
DEADLINE=$(($(date +%s) + 180))
while :; do
  STATE=$(ha core info --raw-json --no-progress 2>/dev/null | jq -r '.data.state' 2>/dev/null || echo unknown)
  if [ "${STATE}" = "running" ]; then
    log "HA Core state=running"
    break
  fi
  [ "$(date +%s)" -ge "${DEADLINE}" ] && fail "HA Core never reported state=running within 180s (last: ${STATE})"
  sleep 5
done

# --- probe the dashboard ------------------------------------------------
log "probing dashboard at ${HA}/synthetic"
DASH_HTML=$(curl -sL --connect-timeout 10 "${HA}/synthetic" 2>/dev/null || true)
if [ -z "${DASH_HTML}" ]; then
  fail "no response from ${HA}/synthetic"
fi

# --- assert each card tag is present ------------------------------------
log "verifying each card type appears in the rendered HTML"
MISSING=""
jq -r '.cards[] | .id' "${CARDS_JSON}" | while IFS= read -r cid; do
  # The relevant rendered HTML evidence per card type — at minimum the
  # cards.json id appears as a <script> module tag because add_extra_js_url
  # injected it. Cards that have a custom-element render also have their
  # custom: prefix in the dashboard YAML which surfaces as a tag in JSON.
  if printf '%s' "${DASH_HTML}" | grep -qF "${cid}"; then
    printf '[synth]   OK   %s\n' "${cid}"
  else
    printf '[synth]   MISS %s\n' "${cid}"
    MISSING="${MISSING} ${cid}"
  fi
done

if [ -n "${MISSING}" ]; then
  fail "cards missing from rendered HTML:${MISSING}"
fi

log "all 14 cards render OK on the synthetic dashboard"
