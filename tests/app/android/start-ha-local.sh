#!/usr/bin/env bash
# android/start-ha-local.sh — Start HA Core in Docker for local app testing
#
# Spins up a HA Core container on the laptop so the Android emulator can
# connect to it at http://10.0.2.2:8123 (the emulator's fixed gateway IP).
#
# Usage:
#   tests/app/android/start-ha-local.sh           # start (default image)
#   tests/app/android/start-ha-local.sh stop      # stop and remove
#   tests/app/android/start-ha-local.sh status    # show running state
#   tests/app/android/start-ha-local.sh logs      # tail container logs
#
# Image selection:
#   Default: ghcr.io/home-assistant/home-assistant:stable (upstream, x86_64)
#            → supports login tests, but no GA onboarding integration
#
#   GA custom (armv7 — requires QEMU emulation):
#     HA_IMAGE=ghcr.io/greenautarky/tinker-homeassistant:2025.11.3.1 \
#       tests/app/android/start-ha-local.sh
#     → supports GA onboarding tests, but slow (~3× slower via QEMU)
#     → requires: sudo apt install qemu-user-static binfmt-support
#
# Environment:
#   HA_IMAGE    — Docker image to use (see above)
#   HA_CONFIG   — host path for /config volume (default: /tmp/ha-local-config)
#   HA_PORT     — host port (default: 8123)
#   CONTAINER   — container name (default: ha-local)

set -euo pipefail

CONTAINER="${CONTAINER:-ha-local}"
HA_PORT="${HA_PORT:-8123}"
HA_CONFIG="${HA_CONFIG:-/tmp/ha-local-config}"
HA_IMAGE="${HA_IMAGE:-ghcr.io/home-assistant/home-assistant:stable}"

CMD="${1:-start}"

case "$CMD" in

  # ── start ────────────────────────────────────────────────────────────────
  start)
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"; then
      echo "Already running: $CONTAINER (http://localhost:$HA_PORT)"
      echo "From emulator:   http://10.0.2.2:$HA_PORT"
      exit 0
    fi

    # Remove stopped container if it exists
    docker rm "$CONTAINER" 2>/dev/null || true

    mkdir -p "$HA_CONFIG"

    echo "Starting HA Core..."
    echo "  Image  : $HA_IMAGE"
    echo "  Config : $HA_CONFIG"
    echo "  Port   : $HA_PORT"
    echo ""

    # Detect if armv7 image needs QEMU
    PLATFORM_ARG=""
    if echo "$HA_IMAGE" | grep -q "tinker-homeassistant"; then
      PLATFORM_ARG="--platform linux/arm/v7"
      echo "  NOTE: armv7 image — running via QEMU (slow, needs qemu-user-static)"
      echo "  Install QEMU if not already: sudo apt install qemu-user-static binfmt-support"
      echo ""
    fi

    # shellcheck disable=SC2086
    docker run -d \
      --name "$CONTAINER" \
      $PLATFORM_ARG \
      -p "${HA_PORT}:8123" \
      -v "${HA_CONFIG}:/config" \
      --restart unless-stopped \
      "$HA_IMAGE"

    echo ""
    echo "Waiting for HA Core to respond..."
    ELAPSED=0
    while [[ $ELAPSED -lt 120 ]]; do
      STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 \
        "http://localhost:${HA_PORT}/api/" 2>/dev/null || echo "000")
      if [[ "$STATUS" == "200" || "$STATUS" == "401" ]]; then
        echo ""
        echo "HA Core ready!"
        echo ""
        echo "  From browser/host : http://localhost:$HA_PORT"
        echo "  From emulator app : http://10.0.2.2:$HA_PORT"
        echo ""
        echo "Run app tests (local mode):"
        echo "  RUN_APP_TESTS=1 tests/run_app_tests.sh --local --admin-pass <pass>"
        exit 0
      fi
      printf "  %ds — HTTP %s ...\r" "$ELAPSED" "$STATUS"
      sleep 5
      ELAPSED=$((ELAPSED + 5))
    done
    echo ""
    echo "WARNING: HA did not respond within 120s — check: docker logs $CONTAINER"
    ;;

  # ── stop ─────────────────────────────────────────────────────────────────
  stop)
    docker stop "$CONTAINER" 2>/dev/null && docker rm "$CONTAINER" 2>/dev/null \
      && echo "Stopped and removed: $CONTAINER" \
      || echo "$CONTAINER not running"
    ;;

  # ── status ───────────────────────────────────────────────────────────────
  status)
    if docker ps --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null \
        | grep "^${CONTAINER}"; then
      STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 \
        "http://localhost:${HA_PORT}/api/" 2>/dev/null || echo "unreachable")
      echo ""
      echo "HTTP status : $STATUS"
      echo "Host URL    : http://localhost:$HA_PORT"
      echo "Emulator URL: http://10.0.2.2:$HA_PORT"
    else
      echo "$CONTAINER is not running"
      echo "Start with: tests/app/android/start-ha-local.sh"
    fi
    ;;

  # ── logs ─────────────────────────────────────────────────────────────────
  logs)
    docker logs -f "$CONTAINER"
    ;;

  *)
    echo "Usage: $(basename "$0") [start|stop|status|logs]"
    exit 1
    ;;
esac
