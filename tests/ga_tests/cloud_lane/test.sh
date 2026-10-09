#!/bin/sh
# Cloud Lane — does a batch handed to ga_manager's local ingest door actually
# leave the device over the MQTT cloud transport, acknowledged by the broker?
#
# WHY THIS SUITE EXISTS
# =====================
# The device -> cloud lane is: producer add-on -> ga_manager POST /cloud/ingest
# -> local spool -> MQTT drain (QoS 1, ga/v1/devices/<serial>/cloud/<table>) ->
# broker -> cloud bridge -> database. Every lane table is produced WEEKLY, so a
# device can sit on a broken lane for days before any real batch would show it.
# This suite publishes ONE synthetic batch itself and follows it to the broker's
# PUBACK, so the device half is proven on every suite run instead of once a week.
#
# What it proves and what it does not:
#   * proves: the door accepts a whitelisted batch; the PRODUCER token (the one
#     ga_manager hands to ga_default_addon) opens the door on the MQTT transport;
#     the drain publishes it and releases it only after the broker's PUBACK; no
#     batch was refused or quarantined on the way.
#   * does NOT prove the cloud half (bridge -> database). That is watched off the
#     device, by the ledger-freshness watcher in the ops repository, which also
#     sees this suite's batch (it lands in the ledger like any other).
#
# Cause found 2026-10-09 (fixed in ga_manager 0.240.1): on the MQTT transport
# the door refused the producer token ga_manager itself delivered (401), because
# it accepted that token only while a database credential block was present —
# which the MQTT transport never has. So no producer batch could enter the lane.
# CL-03 is that check. On ga_manager < 0.240.1 it is skipped with that reason.
#
# The synthetic row: table fact_device_count_summary, this device's own
# core.uuid, timestamp 2000-01-01T00:00:00Z (a sentinel no real producer emits),
# all counts 0. The table's unique key is (device_id, timestamp), so repeated
# runs keep ONE row; every run adds one ledger receipt.
#
# On a device that is NOT on the MQTT transport (cloud_transport db or unset)
# the suite skips everything with that reason: the lane does not apply there.
#
# Red proof hooks (never set in a normal run):
#   CL_TABLE=<table>  post to another table (a non-whitelisted one must make
#                     CL-02 fail with 403)
#   CL_FORCE_PRODUCER=1  run CL-03 even on ga_manager < 0.240.1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Cloud Lane (device -> MQTT cloud transport, synthetic batch to PUBACK)"

CL_TABLE="${CL_TABLE:-fact_device_count_summary}"
GM=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^addon_.*_ga_manager$' | head -1)
GMDATA=$(ls -d /mnt/data/supervisor/addons/data/*_ga_manager 2>/dev/null | head -1)

if [ -z "$GM" ] || [ -z "$GMDATA" ]; then
  show_verdict "CL-00" "ga_manager container and data dir present" 1 \
    "container='${GM}' data='${GMDATA}'"
  suite_end; exit 1
fi

TRANSPORT=$(sed -n 's/^cloud_transport:[[:space:]]*\([a-z]*\).*/\1/p' "$GMDATA/ga-fleet-credentials.yaml" 2>/dev/null | head -1)
if [ "$TRANSPORT" != "mqtt" ]; then
  for t in CL-01 CL-02 CL-03 CL-04 CL-05; do
    skip_test "$t" "MQTT cloud lane" "device not on the MQTT transport (cloud_transport='${TRANSPORT:-unset}')"
  done
  suite_end; exit 0
fi
show_verdict "CL-01" "fleet bundle selects the MQTT cloud transport" 0 "cloud_transport=mqtt"

# gm version from the image tag (…/ga_manager-<arch>:<x.y.z>)
GMV=$(docker inspect --format '{{.Config.Image}}' "$GM" 2>/dev/null | sed -n 's/.*:\([0-9][0-9.]*\)$/\1/p')
# ver_ge A B — A >= B for dotted numeric versions (BusyBox-safe)
ver_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | head -1)" = "$2" ]
}

# post_batch <tokenfile> — POST one sentinel batch through the REAL door from
# inside the ga_manager container. Prints "<http status> <batch_id>".
post_batch() {
  docker exec -i -e TOKFILE="$1" -e CL_TABLE="$CL_TABLE" "$GM" python3 - <<'PY'
import json, os, uuid, urllib.request, urllib.error
core = None
for p in ("/homeassistant/.storage/core.uuid", "/config/.storage/core.uuid"):
    if os.path.exists(p):
        core = json.load(open(p))["data"]["uuid"]; break
bid = str(uuid.uuid4())
if core is None:
    print("000", bid); raise SystemExit(0)
env = {"schema_version": 1, "source": "ga_lane_canary", "batch_id": bid,
       "table": os.environ["CL_TABLE"], "conflict": "nothing",
       "rows": [{"device_id": core, "timestamp": "2000-01-01T00:00:00+00:00",
                 "total_devices": 0, "device_count": 0, "offline_count": 0, "online_count": 0}]}
try:
    tok = open(os.environ["TOKFILE"]).read().strip()
except OSError:
    print("000", bid); raise SystemExit(0)
req = urllib.request.Request("http://127.0.0.1:8099/cloud/ingest", data=json.dumps(env).encode(),
                             headers={"Content-Type": "application/json", "Authorization": "Bearer " + tok})
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        print(r.status, bid)
except urllib.error.HTTPError as e:
    print(e.code, bid)
except Exception:
    print("000", bid)
PY
}

state_field() {  # state_field <key> — integer from cloud-push-state.json, 0 if absent
  sed -n "s/.*\"$1\": *\([0-9][0-9]*\).*/\1/p" "$GMDATA/cloud-push-state.json" 2>/dev/null | head -1
}
in_spool() { grep -rlq "$1" "$GMDATA/cloud_outbox" 2>/dev/null; }

PUBACK0=$(state_field puback_count); PUBACK0=${PUBACK0:-0}
QUAR0=$(state_field quarantined_count); QUAR0=${QUAR0:-0}
REF0=$(state_field refused_count); REF0=${REF0:-0}

# CL-02: the door accepts a whitelisted batch (master token: the door itself)
# shellcheck disable=SC2046 # "<status> <batch_id>" is split on purpose
set -- $(post_batch /data/auth.token)
ST="$1"; BID="$2"
show_verdict "CL-02" "ga_manager /cloud/ingest accepts a whitelisted batch ($CL_TABLE)" \
  "$([ "$ST" = "202" ] && echo 0 || echo 1)" "HTTP $ST batch_id=$BID"

# CL-03: the PRODUCER token (delivered to ga_default_addon) opens the door
if [ -n "$GMV" ] && ! ver_ge "$GMV" "0.240.1" && [ "${CL_FORCE_PRODUCER:-0}" != "1" ]; then
  skip_test "CL-03" "producer ingest token accepted on the MQTT transport" \
    "ga_manager $GMV < 0.240.1 refuses it with 401 (fixed in 0.240.1)"
  PBID=""
else
  # shellcheck disable=SC2046 # split on purpose
  set -- $(post_batch /data/cloud-ingest.token)
  PST="$1"; PBID="$2"
  show_verdict "CL-03" "producer ingest token accepted on the MQTT transport" \
    "$([ "$PST" = "202" ] && echo 0 || echo 1)" "HTTP $PST batch_id=$PBID (ga_manager ${GMV:-?})"
  [ "$PST" = "202" ] || PBID=""
fi

# CL-04: the drain publishes and releases the batch only after PUBACK (interval
# 60 s; allow 4 cycles). Released = gone from the spool AND puback_count grew.
if [ "$ST" = "202" ]; then
  wait_for 240 "! in_spool $BID && [ \"\$(state_field puback_count)\" -gt $PUBACK0 ]"
  PUBACK1=$(state_field puback_count); PUBACK1=${PUBACK1:-0}
  if in_spool "$BID"; then rc=1; why="batch $BID still spooled after 240 s (puback_count $PUBACK0 -> $PUBACK1)"
  elif [ "$PUBACK1" -le "$PUBACK0" ]; then rc=1; why="batch left the spool but puback_count did not grow ($PUBACK0 -> $PUBACK1)"
  else rc=0; why="released after PUBACK (puback_count $PUBACK0 -> $PUBACK1)"; fi
  if [ -n "$PBID" ] && in_spool "$PBID"; then rc=1; why="$why; producer batch $PBID still spooled"; fi
  show_verdict "CL-04" "drain published the batch and the broker acknowledged it" "$rc" "$why"
else
  show_verdict "CL-04" "drain published the batch and the broker acknowledged it" 1 \
    "not attempted: the door refused the batch (HTTP $ST)"
fi

# CL-05: nothing refused or quarantined on the way
QUAR1=$(state_field quarantined_count); QUAR1=${QUAR1:-0}
REF1=$(state_field refused_count); REF1=${REF1:-0}
show_verdict "CL-05" "no batch refused or quarantined during the run" \
  "$([ "$QUAR1" -le "$QUAR0" ] && [ "$REF1" -le "$REF0" ] && echo 0 || echo 1)" \
  "quarantined $QUAR0 -> $QUAR1, refused $REF0 -> $REF1"

suite_end
