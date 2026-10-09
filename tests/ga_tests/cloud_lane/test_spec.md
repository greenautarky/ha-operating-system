# Cloud Lane — test spec

Category: `device`. Runs on a device whose fleet bundle selects `cloud_transport: mqtt`.
On any other device, every check is skipped and the skip names the transport.

| ID | Check | Red when |
|---|---|---|
| CL-01 | The fleet bundle selects the MQTT cloud transport | (gate; otherwise all checks skip) |
| CL-02 | `POST /cloud/ingest` accepts one whitelisted synthetic batch | The door refuses it, e.g. 403 for a table that is not on the cloud whitelist |
| CL-03 | The **producer** ingest token, the one ga_manager delivers to ga_default_addon, opens the door | 401. This was the cause found on 2026-10-09 and fixed in ga_manager 0.240.1. On older ga_manager the check is skipped and says why. |
| CL-04 | The drain publishes the batch, and releases it from the spool only after the broker's PUBACK, within 240 s | The batch is still spooled, or `puback_count` did not grow |
| CL-05 | No batch is refused or quarantined during the run | `quarantined_count` or `refused_count` grew |

The synthetic row is in `fact_device_count_summary`:
- `device_id` is the device's own core.uuid;
- `timestamp` is `2000-01-01T00:00:00Z`, a sentinel that no producer emits;
- all counts are 0.

Every synthetic `batch_id` starts with `5e27111e-`. The ledger watcher in the ops repository uses that prefix to keep these receipts apart from producer receipts: they count only as a lane canary, never as the device's data.

The unique key (device_id, timestamp) keeps it to one row across runs. Each run adds one receipt to the cloud ingest ledger.

The device suite does not check the cloud half (bridge to database). The ledger-freshness watcher in the ops repository checks it; it reads the same ledger these batches land in.

## Red-proof hooks

These are never set in a normal run.
- `CL_TABLE=<non-whitelisted table>`: CL-02 fails with 403 and CL-04 fails.
- `CL_FORCE_PRODUCER=1` on ga_manager < 0.240.1: CL-03 fails with 401.
