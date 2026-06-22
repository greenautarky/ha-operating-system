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

### From source (= local dev / testing)

```bash
docker build -t ga-mosquitto-hup-watcher:dev .
```

### From GHCR (= production)

Image is published by `.github/workflows/ga-mosquitto-hup-watcher.yml`
on any push to master that touches this directory. The version comes
from the `VERSION` file in this directory (= bump it in a PR to ship
a new tagged release):

```bash
docker pull ghcr.io/greenautarky/ga-mosquitto-hup-watcher:0.1.0
# or :latest
```

The image is multi-arch (linux/amd64 + linux/arm64) so the same tag
works on ga-tools (= x86_64) and any future ARM-based ops host.

## Deploy

### 0.2.0+ (= hardened deployment with docker-socket-proxy)

The 0.2.0 release adds a `tecnativa/docker-socket-proxy` sidecar
between the watcher and `/var/run/docker.sock`. The watcher no longer
mounts the host's docker socket directly; it talks to the proxy over
a private bridge network. The proxy is configured to allow ONLY
`GET /containers/json` + `POST /containers/{id}/kill`. All other API
endpoints (start/stop/restart/exec/build/pull/push/volumes/networks
etc.) return 403.

See `docker-compose.snippet.yaml` for the full configuration. Add the
two services + the `hup-watcher-private` network to ga-tools'
`~/mosquitto/docker-compose.yml`, then `docker compose up -d`.

Rationale: docker.sock access widens a container's blast radius
significantly (= a compromise can issue any Docker API call to the
host). The proxy reduces this to "list containers + send signals" —
no escape path to volume mounting, container spawning, or image
pulls. See `memory/privacy_review_phase_1g_watcher_2026_06_22.md`
for the audit + the Phase 2 hardening recommendation.

### 0.1.0 (= legacy, direct socket mount — STILL works, kept for back-compat)

```yaml
mosquitto-hup-watcher:
  image: ghcr.io/greenautarky/ga-mosquitto-hup-watcher:0.1.0
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

Operators are recommended to migrate to 0.2.0 before non-canary
rollout — the privacy review memo flags the unproxied socket as a
hardening prerequisite.

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
