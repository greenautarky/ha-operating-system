#!/bin/sh
# The LIVE suite against a stub docker: green on the pinned state, red on each deviation.
HERE="$(cd "$(dirname "$0")" && pwd)"; W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
ran=0; fails=0
cat > "$W/docker" <<'D'
#!/bin/sh
case "$*" in
  "ps -a --format {{.Names}} {{.Image}}") cat "$ST" ;;
  "ps --format {{.Names}}") cut -d' ' -f1 "$ST"; echo homeassistant ;;
  *io.hass.version*hassio_supervisor*) cat "$ST.sup" ;;
  *.Config.Image*) for n; do :; done; [ "$n" = homeassistant ] && { cat "$ST.core"; exit; }; awk -v n="$n" '$1==n{print $2; f=1} END{exit !f}' "$ST" ;;
  *) exit 1 ;;
esac
D
chmod +x "$W/docker"
good() { # good BOARD: the pinned state
  . "$HERE/expected.$1.env"; B="$1"; ST="$W/st"; : > "$ST"; export ST
  for p in $VR_ADDONS; do k="${p%%=*}"; [ "$k" = sonoff_dongle_flasher ] && continue; echo "app_99f1cad4_$k ${p#*=}" >> "$ST"; done # ga-ctr-ok
  echo "ghcr.io/x/core:$VR_CORE" > "$ST.core"; echo "$VR_SUPERVISOR" > "$ST.sup"
  fv="$(echo "$VR_ADDONS" | tr ' ' '\n' | sed -n 's/^sonoff_dongle_flasher=.*://p')"
  printf '{"user":{"99f1cad4_sonoff_dongle_flasher_for_ihost":{"version":"%s"}}}' "$fv" > "$W/apps.json"
}
t() { # t NAME want(0/1) TEST-ID
  ran=$((ran+1)); out="$(PATH="$W:$PATH" VR_FORCE_BOARD="$B" VR_WAIT=1 VR_APPS_JSON="$W/apps.json" sh "$HERE/test.sh" 2>&1)"
  failed="$(echo "$out" | grep -oE 'FAIL.*VRUN-[0-9]+|VRUN-[0-9]+.*FAIL' | grep -oE 'VRUN-[0-9]+' | sort -u | tr '\n' ' ')"
  if [ "$2" = 0 ]; then [ -z "$failed" ] && echo "$out" | grep -q VRUN-90; else [ "$failed" = "$3 " ]; fi
  if [ $? = 0 ]; then echo "  ok    $1"; else fails=$((fails+1)); echo "  FAIL  $1 (failed: $failed)"; echo "$out" | tail -5; fi
}
id() { i=10; for p in $VR_ADDONS; do [ "${p%%=*}" = "$1" ] && echo "VRUN-$i"; i=$((i+1)); done; }
for b in ihost dsgw210; do
  good $b; t "MUST-PASS $b: the pinned state" 0
  good $b; sed -i '/ga_influxdbv1/s/:[^:]*$/:0.0.23/' "$ST"; t "MUST-FLAG $b: rc3 state, an older influx runs" 1 "$(id ga_influxdbv1)"
  good $b; sed -i '/ga_manager/s/:[^:]*$/:9.9.9/' "$ST"; t "MUST-FLAG $b: a newer ga_manager runs" 1 "$(id ga_manager)"
  good $b; sed -i '/ga_mosquitto/d' "$ST"; t "MUST-FLAG $b: an add-on is missing" 1 "$(id mosquitto)"
  good $b; sed -i '/ga_zigbee2mqtt/s#ghcr.io/greenautarky#ghcr.io/other#' "$ST"; t "MUST-FLAG $b: another repository" 1 "$(id ga_zigbee2mqtt)"
  good $b; sed -n '/ga_manager/p' "$ST" | sed 's/^app/old/' >> "$ST"; t "MUST-FLAG $b: two containers of one add-on" 1 "$(id ga_manager)"
  good $b; echo "ghcr.io/x/core:2026.1.1" > "$ST.core"; t "MUST-FLAG $b: another Core" 1 VRUN-01
  good $b; : > "$ST.sup"; t "MUST-FLAG $b: Supervisor unreadable" 1 VRUN-02
done
good ihost; echo '{"user":{}}' > "$W/apps.json"; t "MUST-FLAG ihost: the install-only flasher is not installed" 1 "$(id sonoff_dongle_flasher)"
good ihost; B=riscv; ran=$((ran+1)); PATH="$W:$PATH" VR_FORCE_BOARD=riscv sh "$HERE/test.sh" 2>&1 | grep -q 'FAIL' && echo "  ok    MUST-FLAG unknown board" || { fails=$((fails+1)); echo "  FAIL  unknown board"; }
echo "versions_running selftest: $ran checks, $fails failed"; [ "$ran" -ge 18 ] && [ "$fails" = 0 ]
