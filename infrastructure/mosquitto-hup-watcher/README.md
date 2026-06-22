# mosquitto-hup-watcher

Phase 1g sidecar — watches `/mosquitto/config` via inotify and SIGHUPs the mosquitto container whenever the config files change. With debounce. Completes the cohort-management end-to-end automation:

```
Operator: POST /api/devices/<id>/tags  (= 1 API call)
            │
            ▼
fleet-manager: tag db row + acl_sync regenerates passwd + acl on disk
            │
            ▼
this watcher: inotify MOVED_TO acl → 2s debounce → docker kill --signal=HUP mosquitto
            │
            ▼
mosquitto: reloads ACL (= new cohort read line for the device now active)
            │
            ▼ (parallel)
fleet-manager: tag-push MQTT cmd to device
            │
            ▼
device ga_manager: writes /share/ga-device-tags.json + hot-resubscribes cohort topics
            │
            ▼
                       ✅ Operator-visible result: tag added, cohort subscribed, no SSH, no restart
```

See `memory/design_phase_1g_mosquitto_hup_2026_06_22.md` for the design rationale.

## Build

```bash
docker build -t ga-mosquitto-hup-watcher:0.1.0 .
```

## Deploy

Add to ga-tools' `~/mosquitto/docker-compose.yml`:

```yaml
mosquitto-hup-watcher:
  image: ga-mosquitto-hup-watcher:0.1.0
  container_name: mosquitto-hup-watcher
  restart: unless-stopped
  volumes:
    - ./config:/mosquitto/config:ro
    - /var/run/docker.sock:/var/run/docker.sock
  environment:
    - WATCH_DIR=/mosquitto/config
    - TARGET_CONTAINER=mosquitto
    - DEBOUNCE_SECS=2
  depends_on:
    - mosquitto
```

Then `docker compose up -d`.

## Verify

```bash
# Watch the watcher log:
docker logs --tail 20 -f mosquitto-hup-watcher

# Touch a config file to trigger:
touch ~/mosquitto/config/acl  # (= or any file inside /mosquitto/config)

# Expect log lines:
# [hup-watcher] event: MODIFY acl ...
# [hup-watcher] SIGHUP'd mosquitto (last event was ...)

# And in mosquitto's log:
docker logs --tail 5 mosquitto | grep -i reload
# 1782154729: Reloading config.
```

## Operational notes

- **docker.sock access**: the watcher needs to send signals to a sibling container. The container does nothing else; review the 40-line `watch.sh` to verify.
- **Read-only config mount**: the watcher cannot WRITE to the config — only the bind-mount comes through as read-only. Operator-side accidents (= `rm -rf /mosquitto/config` from within the watcher) are impossible.
- **Failure recovery**: if `docker kill` fails (= mosquitto restarting, target unreachable), the watcher logs + waits for the next event. On a long mosquitto outage, the ACL file changes during that time are not lost — once mosquitto is back + the watcher's next event fires, the HUP arrives.
- **Privacy**: see Phase 1g design memo "Privacy review touch" section.

## Future

This is a copy-on-disk in ha-operating-system for source tracking. The intended forever home is a dedicated repo `greenautarky/ga-mosquitto-hup-watcher` with CI publishing to GHCR.
