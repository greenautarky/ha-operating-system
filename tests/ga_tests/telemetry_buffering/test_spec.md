# Telemetry buffering — test spec

Edge-buffered telemetry: telegraf's native disk store-and-forward + the
ga_manager network-signal file-drop. See
`ga-ihost-docs/TELEMETRY-DATA-FLOW.md` and the ADR.

## Automated (BUF-01..07, in `test.sh`, consent-gated)

| ID | Checks |
|---|---|
| BUF-00 | metrics consent gate (suite N/A without consent) |
| BUF-01 | `buffer_strategy=disk_write_through` in the active config |
| BUF-02 | buffer dir under `/mnt/data` exists |
| BUF-03 | telegraf loaded the ga-network `inputs.file` |
| BUF-04 | telegraf loaded `inputs.temp` (cpu temperature) |
| BUF-05 | ga_manager is writing the signal file with a `network_signal` point |
| BUF-06 | no recent telegraf write/connection errors (buffer draining) |
| BUF-07 | write-on-change (mtime stable when signal stable) — informational |

## Semi-manual: outage + reboot back-fill proof (BUF-10..13)

The core guarantee — **signal survives a reboot DURING an outage and is
back-filled, with no data loss**. Run on a canary (K0 or K49). Needs the
InfluxDB IP and a query tool on ga-tools.

```sh
# BUF-10 — induce an outage: drop egress to the InfluxDB host
INFLUX_IP=$(getent hosts influx.greenautarky.com | awk '{print $1}')
nft add rule inet filter output ip daddr "$INFLUX_IP" drop   # or iptables -A OUTPUT -d $INFLUX_IP -j DROP
date -u +%FT%TZ            # note T0

# BUF-11 — let metrics accumulate, then confirm the buffer is filling
sleep 600
ls -la /mnt/data/telegraf/buffer            # WAL files present + growing
du -sh /mnt/data/telegraf/buffer            # stays small (bounded by metric_buffer_limit)

# BUF-12 — REBOOT mid-outage (the part RAM-only buffering loses)
systemctl reboot
#   ... device comes back; egress STILL dropped (rule may not survive reboot —
#   re-apply the nft/iptables drop right after boot if it cleared) ...

# BUF-13 — restore egress + verify back-fill
nft flush ruleset    # or remove the specific DROP rule
date -u +%FT%TZ      # note T1
sleep 600            # let telegraf drain the buffer

# On ga-tools — assert the signal series has NO gap across [T0, T1]:
#   SELECT count(active_signal_dbm) FROM device_metrics.autogen.network_signal
#   WHERE device_id='KIB-SON-00000049' AND time > T0 AND time < T1
#   → count == expected (≈ (T1-T0)/60s), i.e. the outage+reboot window is filled.
```

**Pass:** the `network_signal` (and other) series show continuous coverage
across the outage+reboot window — the buffer persisted across the reboot and
back-filled on recovery. **Fail:** a gap during the outage = the disk buffer
did not persist (regression).

> Tip: run the fast loop with `/mnt/data/telegraf/override.conf` so you can
> iterate without an OS rebuild (`telegraf.service` prefers the override).
