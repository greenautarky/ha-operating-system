#!/usr/bin/env bash
# Phase 1g — mosquitto HUP watcher (= sidecar).
# Watches $WATCH_DIR for ANY change (close_write, move, delete) +
# SIGHUPs $TARGET_CONTAINER after $DEBOUNCE_SECS of silence.
#
# Design: [[design_phase_1g_mosquitto_hup_2026_06_22]].

set -u
LOG_PREFIX="[hup-watcher]"
echo "$LOG_PREFIX starting — watching $WATCH_DIR, target=$TARGET_CONTAINER, debounce=${DEBOUNCE_SECS}s"

# Sanity: docker.sock reachable + target container exists.
if ! docker ps --format '{{.Names}}' | grep -q "^$TARGET_CONTAINER\$"; then
    echo "$LOG_PREFIX WARN: target container $TARGET_CONTAINER not running at start. Will retry on each fired event."
fi

# inotifywait monitors closure events (= safest signal that a write
# completed). atomic-rename writes trigger close_write on the new file +
# moved_to on the renamed name. We just react to "something changed" +
# debounce.
hup_pending=0
last_event_ts=0

# Use a background inotifywait emitting a line per event. The main
# loop reads lines + tracks debounce.
inotifywait -mq -e close_write -e move -e create -e delete --format '%e %f' "$WATCH_DIR" |
while read -r event_line; do
    now_ts=$(date +%s)
    echo "$LOG_PREFIX event: $event_line at $now_ts"
    last_event_ts=$now_ts
    hup_pending=1

    # Sub-shell loop: keep reading more events while they arrive, but
    # once DEBOUNCE_SECS elapse without an event, fire the HUP.
    while [[ $hup_pending -eq 1 ]]; do
        if read -r -t "$DEBOUNCE_SECS" event_line2; then
            now_ts=$(date +%s)
            echo "$LOG_PREFIX additional event during debounce: $event_line2"
            last_event_ts=$now_ts
        else
            # Debounce window elapsed without further events → fire HUP.
            if docker kill --signal=HUP "$TARGET_CONTAINER" >/dev/null 2>&1; then
                echo "$LOG_PREFIX SIGHUP'd $TARGET_CONTAINER (last event was ${last_event_ts})"
            else
                echo "$LOG_PREFIX HUP failed — target unreachable. Will retry on next event."
            fi
            hup_pending=0
        fi
    done
done

echo "$LOG_PREFIX inotifywait exited — restart will retry"
