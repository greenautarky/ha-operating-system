#!/usr/bin/env bash
# provision-e2e.sh — the fresh-flash provisioning gate for a new build.
#
# WHY THIS EXISTS
# ---------------
# The canary ring proves the OTA path. Nothing proved the OTHER path: SD card
# written from a build → first boot → device provisions itself → done. That is
# the path every new device rides on, and it is the less tested of the two.
# On 2026-07-30 an image was structurally intact, passed 297 build checks, and
# no device could finish provisioning on it — invisible until someone flashed a
# card and watched. On 2026-08-17 the chain worked to the release and then wrote
# a "converged" marker over per-device steps it had silently skipped, while the
# on-device self-check reported PASSED.
#
# Both were found by flashing and watching. This is that, as a script, with
# deadlines, so it can run after every bake instead of when someone remembers.
#
# It cannot run on a GitHub runner: it needs a card, a MUX and a power plug. It
# runs wherever ssh reaches the bench and the fleet-manager.
#
# WHAT IT ASSERTS (in order, each with a deadline from power-on)
#   1. the card was written completely            — byte count + PIPESTATUS, never a pipe's exit code
#   2. the device booted                          — its USB serial gadget comes back
#   3. it enrolled itself                         — fleet-manager sees hw_serial, status=pending
#   4. the pairing released it                    — status=released, device_id assigned, peer promoted
#   5. it converged, WITH its identity            — graded by check_phase_invariants.sh
#
# Step 5 does not re-implement the grading: it reads the four facts off the
# device over serial, materialises them as a fixture-shaped tree locally, and
# runs the same check script that tests/ga_tests/provisioning/selftest.sh proves
# can go red and green. One definition, three callers.
#
# USAGE
#   provision-e2e.sh --device KIB-SON-00000031 --image /path/on/bench.img.xz
#   provision-e2e.sh --device KIB-SON-00000031 --from-builder bos_ihost-…img.xz
#   provision-e2e.sh --verify-only <root>        # grade a tree, no hardware
#
# EXIT CODES
#   0 pass · 1 a deadline or an invariant failed · 2 preflight refused to start
set -uo pipefail

BENCH="${BENCH_SSH:-remote1}"
FM_SSH="${FM_SSH:-ga-newhost}"
FM_URL="${FM_URL:-http://127.0.0.1:8090}"
FM_TOKEN_PATH="${FM_TOKEN_PATH:-/home/thomas/ga-fleet-manager/state/auth.token}"
BUILDER_SSH="${BUILDER_SSH:-homes4}"            # reaches the builder LXC
BUILDER_CT="${BUILDER_CT:-107}"
BUILDER_IMAGE_DIR="${BUILDER_IMAGE_DIR:-/home/builder/ha-operating-system/ga_output/images}"
BENCH_SERIAL_HELPER="${BENCH_SERIAL_HELPER:-\$HOME/git/ga-flasher-py/work/serial_run.py}"
BENCH_SERIAL_PW="${BENCH_SERIAL_PW:-\$HOME/git/ga-flasher-py/work/serial-password.txt}"

PLUG="${PLUG:-13}"                 # A16 label — 13 is K31 on remote1
HUB="${HUB:-2-1.3.3}"              # uhubctl resolves this to the paired USB2 hub
HUB_PORT="${HUB_PORT:-1}"          # label 13 = hub port 1
SERIAL_DEV="${SERIAL_DEV:-/dev/a16-port13}"
MUX_ID="${MUX_ID:-}"               # auto-detected when empty

DEADLINE_PENDING_S="${DEADLINE_PENDING_S:-360}"     # enroll   — measured 2:43
DEADLINE_RELEASED_S="${DEADLINE_RELEASED_S:-600}"   # release  — measured 3:54
DEADLINE_CONVERGED_S="${DEADLINE_CONVERGED_S:-1500}" # converge — measured 12:27 (baseline)

DEVICE_ID=""; IMAGE=""; FROM_BUILDER=""; VERIFY_ONLY=""
SIMULATE_FRESH=1; SKIP_FLASH=0; JSON_OUT=""

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SCRIPT="$HERE/../ga_tests/provisioning/check_phase_invariants.sh"

die()  { echo "REFUSED: $*" >&2; exit 2; }
fail() { echo "FAIL: $*" >&2; VERDICT_FAILED=1; }
log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
VERDICT_FAILED=0
declare -a TIMELINE=()
T0=0

mark() { # mark <label>
  local now; now=$(date +%s)
  TIMELINE+=("$1|$(( T0 ? now - T0 : 0 ))")
  log "→ $1 (t+$(( T0 ? now - T0 : 0 ))s)"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)        DEVICE_ID="$2"; shift 2 ;;
    --image)         IMAGE="$2"; shift 2 ;;
    --from-builder)  FROM_BUILDER="$2"; shift 2 ;;
    --verify-only)   VERIFY_ONLY="$2"; shift 2 ;;
    --plug)          PLUG="$2"; shift 2 ;;
    --serial)        SERIAL_DEV="$2"; shift 2 ;;
    --mux-id)        MUX_ID="$2"; shift 2 ;;
    --keep-enrollment) SIMULATE_FRESH=0; shift ;;
    --skip-flash)    SKIP_FLASH=1; shift ;;
    --json)          JSON_OUT="$2"; shift 2 ;;
    -h|--help)       sed -n '2,40p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *)               die "unknown argument: $1" ;;
  esac
done

# ── fm helpers ──────────────────────────────────────────────────────────
fm() { # fm <method> <path> [body]
  local method="$1" path="$2" body="${3:-}"
  # shellcheck disable=SC2029  # deliberate: the command is built here
  ssh -o BatchMode=yes "$FM_SSH" "T=\$(cat $FM_TOKEN_PATH) && curl -sS -m 20 \
    -X $method -H \"Authorization: Bearer \$T\" -H 'Content-Type: application/json' \
    ${body:+-d '$body'} '$FM_URL$path'"
}

enrollment_field() { # enrollment_field <hw_serial> <field>
  fm GET /api/enrollments | python3 -c "
import json,sys
rows = json.load(sys.stdin)['enrollments']
row = next((r for r in rows if r.get('hw_serial') == '$1'), None)
print('' if row is None else (row.get('$2') if row.get('$2') is not None else ''))
" 2>/dev/null
}

# ── grading (shared definition, never a copy) ───────────────────────────
grade_tree() { # grade_tree <root>
  [[ -x "$CHECK_SCRIPT" ]] || die "grading script missing: $CHECK_SCRIPT"
  local out; out="$(sh "$CHECK_SCRIPT" "$1")"
  [[ -n "$out" ]] || { fail "grading produced no verdict — refusing to call that a pass"; return 1; }
  echo "$out" | while read -r id status detail; do
    printf '  %-9s %-5s %s\n' "$id" "$status" "$detail"
  done
  if echo "$out" | awk '$2=="fail"{found=1} END{exit !found}'; then
    fail "phase invariants failed — see the lines above"
    return 1
  fi
  return 0
}

# ── verify-only: no hardware, used for the red/green proof ──────────────
if [[ -n "$VERIFY_ONLY" ]]; then
  [[ -d "$VERIFY_ONLY" ]] || die "not a directory: $VERIFY_ONLY"
  echo "== grading tree: $VERIFY_ONLY =="
  grade_tree "$VERIFY_ONLY"
  [[ $VERDICT_FAILED -eq 0 ]] && { echo "VERDICT: pass"; exit 0; }
  echo "VERDICT: fail"; exit 1
fi

# ── preflight — refuse, never limp ──────────────────────────────────────
[[ -n "$DEVICE_ID" ]] || die "--device KIB-SON-XXXXXXXX is required"
[[ "$DEVICE_ID" =~ ^[A-Z]+(-[A-Z0-9]+)+$ ]] || die "device id must be canonical: $DEVICE_ID"
[[ -x "$CHECK_SCRIPT" ]] || die "grading script missing/not executable: $CHECK_SCRIPT"
if [[ $SKIP_FLASH -eq 0 ]]; then
  [[ -n "$IMAGE$FROM_BUILDER" ]] || die "--image or --from-builder is required (or --skip-flash)"
fi

log "preflight"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$BENCH" true \
  || die "bench unreachable over ssh: $BENCH"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$FM_SSH" true \
  || die "fleet-manager host unreachable over ssh: $FM_SSH"

# The pairing must already exist, or the release can never fire and the run
# would time out 25 minutes later reporting the wrong cause.
LABEL_HTTP="$(fm GET "/api/label-credentials/$DEVICE_ID" | head -c 400)"
echo "$LABEL_HTTP" | grep -q '"url_prefix"' \
  || die "no label credentials for $DEVICE_ID in the fleet-manager — scan/generate the label first ($LABEL_HTTP)"
log "label credentials present for $DEVICE_ID"

if [[ -z "$MUX_ID" && $SKIP_FLASH -eq 0 ]]; then
  MUX_ID="$(ssh "$BENCH" 'ls /dev/usb-sd-mux/ 2>/dev/null | head -1')"
  [[ -n "$MUX_ID" ]] || die "no USB-SD-MUX found on $BENCH"
  log "MUX auto-detected: $MUX_ID"
fi

# hw_serial: the pairing match key. Read it from the fleet-manager's existing
# enrollment for this device, else off the device over serial.
HW_SERIAL="$(fm GET /api/enrollments | python3 -c "
import json,sys
rows = json.load(sys.stdin)['enrollments']
row = next((r for r in rows if r.get('device_id') == '$DEVICE_ID'), None)
print(row['hw_serial'] if row else '')
" 2>/dev/null)"
if [[ -z "$HW_SERIAL" ]]; then
  log "no enrollment for $DEVICE_ID yet — reading hw_serial off the device over serial"
  HW_SERIAL="$(ssh "$BENCH" "cd \$HOME/git/ga-flasher-py && timeout 90 python3 $BENCH_SERIAL_HELPER $SERIAL_DEV root $BENCH_SERIAL_PW --shell \
    \"tr -d '\\0' < /sys/firmware/devicetree/base/serial-number\" 2>/dev/null" \
    | sed -n 's/^\([0-9a-f]\{8,\}\)$/\1/p' | head -1)"
fi
[[ -n "$HW_SERIAL" ]] || die "could not determine hw_serial for $DEVICE_ID (needed to watch the enrollment)"
log "hw_serial: $HW_SERIAL"

# ── stage the image ─────────────────────────────────────────────────────
if [[ $SKIP_FLASH -eq 0 && -n "$FROM_BUILDER" ]]; then
  log "staging $FROM_BUILDER from the builder onto $BENCH"
  EXPECTED_SHA="$(ssh "$BUILDER_SSH" "pct exec $BUILDER_CT -- cat $BUILDER_IMAGE_DIR/$FROM_BUILDER.sha256" \
    | awk '{print $1}')"
  [[ -n "$EXPECTED_SHA" ]] || die "no .sha256 next to $FROM_BUILDER on the builder"
  IMAGE="/home/thomas/$FROM_BUILDER"
  ssh "$BUILDER_SSH" "pct exec $BUILDER_CT -- cat $BUILDER_IMAGE_DIR/$FROM_BUILDER" \
    | ssh "$BENCH" "cat > $IMAGE" || die "image transfer failed"
  GOT_SHA="$(ssh "$BENCH" "sha256sum $IMAGE" | awk '{print $1}')"
  [[ "$GOT_SHA" == "$EXPECTED_SHA" ]] \
    || die "sha256 mismatch after transfer: $GOT_SHA != $EXPECTED_SHA"
  log "sha256 verified: $EXPECTED_SHA"
fi

# ── flash ───────────────────────────────────────────────────────────────
if [[ $SKIP_FLASH -eq 0 ]]; then
  log "powering the device off (A16 label $PLUG)"
  ssh "$BENCH" "sudo -n /usr/sbin/uhubctl -l $HUB -p $HUB_PORT -a off >/dev/null" \
    || die "could not cut power to label $PLUG"
  ssh "$BENCH" "sudo -n usbsdmux /dev/usb-sd-mux/$MUX_ID host" || die "MUX → host failed"
  sleep 3
  CARD_SIZE="$(ssh "$BENCH" "lsblk -bno SIZE /dev/sda 2>/dev/null | head -1")"
  [[ "${CARD_SIZE:-0}" -gt 0 ]] || die "no card visible on the host side after MUX switch"

  log "writing the image (this takes ~9 min at ~19 MB/s)"
  # PIPESTATUS, not the pipe's exit code: a failed dd behind a pipe reports 0.
  FLASH_OUT="$(ssh "$BENCH" "bash -c 'set -o pipefail; xzcat $IMAGE | sudo -n dd of=/dev/sda bs=4M conv=fsync status=none; \
    echo PIPESTATUS=\${PIPESTATUS[*]}; sync; blockdev --getsize64 /dev/sda'")"
  echo "$FLASH_OUT" | grep -q 'PIPESTATUS=0 0' \
    || { fail "flash did not complete cleanly: $FLASH_OUT"; exit 1; }
  log "flash complete, PIPESTATUS clean"

  ssh "$BENCH" "sudo -n usbsdmux /dev/usb-sd-mux/$MUX_ID dut" || die "MUX → dut failed"
fi

# ── purge the enrollment so the device looks factory-fresh ──────────────
# The pairing (keyed on hw_serial) is deliberately KEPT: that is the production
# flow, where the label was scanned before the device ever booted.
if [[ $SIMULATE_FRESH -eq 1 ]]; then
  log "purging the enrollment for $HW_SERIAL (pairing kept — the production flow)"
  fm DELETE "/api/enrollments/$HW_SERIAL" >/dev/null 2>&1 || true
fi

# ── power on and measure ────────────────────────────────────────────────
T0=$(date +%s)
log "POWER ON"
ssh "$BENCH" "sudo -n /usr/sbin/uhubctl -l $HUB -p $HUB_PORT -a on >/dev/null" \
  || die "could not power on label $PLUG"
mark power_on

log "waiting for the USB serial gadget to return (proves the kernel booted)"
booted=0
for _ in $(seq 1 60); do
  if ssh "$BENCH" "test -e $SERIAL_DEV"; then booted=1; break; fi
  sleep 5
done
[[ $booted -eq 1 ]] && mark gadget_back || fail "serial gadget never came back — the device did not boot"

wait_for_status() { # wait_for_status <wanted> <deadline_s> <label>
  local wanted="$1" deadline="$2" label="$3" now
  while :; do
    now=$(date +%s)
    if (( now - T0 > deadline )); then
      fail "$label not reached within ${deadline}s (last status: '$(enrollment_field "$HW_SERIAL" status)')"
      return 1
    fi
    [[ "$(enrollment_field "$HW_SERIAL" status)" == "$wanted" ]] && { mark "$label"; return 0; }
    sleep 10
  done
}

wait_for_status pending  "$DEADLINE_PENDING_S"  enrolled_pending
wait_for_status released "$DEADLINE_RELEASED_S" released

if [[ "$(enrollment_field "$HW_SERIAL" device_id)" != "$DEVICE_ID" ]]; then
  fail "released under the wrong device_id: '$(enrollment_field "$HW_SERIAL" device_id)' != $DEVICE_ID"
fi
PROMOTED="$(enrollment_field "$HW_SERIAL" promoted_netbird_ip)"
CURRENT_IP="$(enrollment_field "$HW_SERIAL" netbird_ip)"
if [[ -n "$CURRENT_IP" && "$PROMOTED" == "$CURRENT_IP" ]]; then
  mark peer_promoted
else
  fail "peer not promoted for the current mesh IP (promoted='$PROMOTED' current='$CURRENT_IP') — the device stays quarantined inbound"
fi

# ── converge, graded from the device's own facts ─────────────────────────
log "waiting for full convergence (deadline ${DEADLINE_CONVERGED_S}s)"
SNAP="$(mktemp -d)"; trap 'rm -rf "$SNAP"' EXIT
converged=0
while :; do
  now=$(date +%s)
  (( now - T0 > DEADLINE_CONVERGED_S )) && break
  facts="$(ssh "$BENCH" "cd \$HOME/git/ga-flasher-py && timeout 90 python3 $BENCH_SERIAL_HELPER $SERIAL_DEV root $BENCH_SERIAL_PW --shell \
    \"S=/mnt/data/supervisor/share; H=/mnt/data/supervisor/homeassistant; \
      G=\\\$(ls -d /mnt/data/supervisor/addons/data/*ga_manager 2>/dev/null | head -1); \
      echo FULL=\\\$([ -f \\\$S/.ga_converged ] && echo 1 || echo 0); \
      echo BASE=\\\$([ -f \\\$S/.ga_converged_base ] && echo 1 || echo 0); \
      echo PIN=\\\$([ -s \\\$H/.storage/greenautarky_secrets/onboarding_pin ] || [ -s \\\$H/ga-onboarding-pin ] && echo 1 || echo 0); \
      echo PARKED=\\\$([ -f \\\$G/ga-generated-admin-pw ] && echo 1 || echo 0); \
      echo IDENTITY_BEGIN; cat \\\$S/ga-identity.json 2>/dev/null; echo IDENTITY_END\" " 2>/dev/null)"
  if echo "$facts" | grep -q '^FULL=1'; then converged=1; fi
  if [[ $converged -eq 1 ]]; then mark converged; break; fi
  sleep 20
done
[[ $converged -eq 1 ]] || fail "device never reported full convergence within ${DEADLINE_CONVERGED_S}s"

# Materialise the device's facts as a fixture-shaped tree, then grade with the
# shared script — so this gate and the CI self-test cannot disagree.
mkdir -p "$SNAP/mnt/data/supervisor/share" \
         "$SNAP/mnt/data/supervisor/homeassistant/.storage/greenautarky_secrets" \
         "$SNAP/mnt/data/supervisor/addons/data/99f1cad4_ga_manager"
grep -q '^FULL=1'   <<<"$facts" && echo converged > "$SNAP/mnt/data/supervisor/share/.ga_converged"
grep -q '^BASE=1'   <<<"$facts" && echo baseline  > "$SNAP/mnt/data/supervisor/share/.ga_converged_base"
grep -q '^PIN=1'    <<<"$facts" && echo 000000    > "$SNAP/mnt/data/supervisor/homeassistant/.storage/greenautarky_secrets/onboarding_pin"
grep -q '^PARKED=1' <<<"$facts" && echo parked    > "$SNAP/mnt/data/supervisor/addons/data/99f1cad4_ga_manager/ga-generated-admin-pw"
sed -n '/^IDENTITY_BEGIN/,/^IDENTITY_END/p' <<<"$facts" | sed '1d;$d' \
  > "$SNAP/mnt/data/supervisor/share/ga-identity.json"

echo
echo "== phase invariants (graded by check_phase_invariants.sh) =="
grade_tree "$SNAP" || true

# ── report ──────────────────────────────────────────────────────────────
echo
echo "== timeline (t+ seconds from power-on) =="
for e in "${TIMELINE[@]}"; do printf '  %-18s %s\n' "${e%%|*}" "t+${e##*|}s"; done

if [[ -n "$JSON_OUT" ]]; then
  { echo "{"
    echo "  \"device_id\": \"$DEVICE_ID\", \"hw_serial\": \"$HW_SERIAL\","
    echo "  \"image\": \"${FROM_BUILDER:-$IMAGE}\", \"passed\": $([[ $VERDICT_FAILED -eq 0 ]] && echo true || echo false),"
    printf '  "timeline": {'
    sep=""
    for e in "${TIMELINE[@]}"; do printf '%s"%s": %s' "$sep" "${e%%|*}" "${e##*|}"; sep=", "; done
    echo "}"
    echo "}"
  } > "$JSON_OUT"
  log "wrote $JSON_OUT"
fi

echo
if [[ $VERDICT_FAILED -eq 0 ]]; then
  echo "VERDICT: pass — $DEVICE_ID provisioned itself from ${FROM_BUILDER:-$IMAGE} with no operator step after power-on"
  exit 0
fi
echo "VERDICT: fail — see the FAIL lines above"
exit 1
