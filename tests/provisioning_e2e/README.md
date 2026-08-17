# Fresh-flash provisioning gate

The canary ring proves the **OTA** path. This proves the other one:

```
SD card written from a build → first boot → the device provisions itself → done
```

That is the path every new device rides on, and it is the less tested of the
two. Twice it broke and nothing reported it:

- **2026-07-30** — an image passed 297 build checks and no device on it could
  finish provisioning. `HASSIO_VERSION_URL` pointed at a branch pinning a stale
  Supervisor, so a job condition blocked StoreManager, so ga-bootstrap could not
  register the add-on store. Every device booted fine and answered on serial.
- **2026-08-17** — the chain worked to the release in 3 min 54 s and then wrote
  a `converged` marker over per-device steps it had silently skipped, because
  converge held the single job runner while the fleet-manager's identity-write
  queued behind it. The device's own self-check reported `PASSED — 12 ok`.

Both were found by flashing a card and watching for twenty minutes. This is
that, with deadlines.

## Run it

```bash
# after a bake, against the bench canary
./tests/provisioning_e2e/provision-e2e.sh \
    --device KIB-SON-00000031 \
    --from-builder bos_ihost-16.3.1.9_dev_20260730184450.img.xz \
    --json /tmp/provision-e2e.json

# image already on the bench
./provision-e2e.sh --device KIB-SON-00000031 --image /home/thomas/gaos.img.xz

# grade a device tree, no hardware (this is what CI runs)
./provision-e2e.sh --verify-only tests/ga_tests/provisioning/fixtures/must-pass-converged
```

Exit codes: `0` pass · `1` a deadline or an invariant failed · `2` preflight
refused to start.

## What it asserts, and with which deadline

| # | assertion | how | deadline from power-on |
|---|---|---|---|
| 1 | the card was written completely | byte count + `PIPESTATUS`, never a pipe's exit code | — |
| 2 | the device booted | its USB serial gadget returns | 5 min |
| 3 | it enrolled itself | fleet-manager sees `hw_serial`, `status=pending` | 6 min (measured 2:43) |
| 4 | the pairing released it | `status=released`, right `device_id`, **peer promoted for the current mesh IP** | 10 min (measured 3:54) |
| 5 | it converged **with** its identity | graded by `check_phase_invariants.sh` | 25 min (measured 12:27) |

Step 5 does not re-implement the grading. It reads the four facts off the device
over serial, materialises them as a fixture-shaped tree, and runs the same
script the device suite and the CI self-test run. One definition, three callers —
so the gate and the suite cannot drift into disagreeing about what "provisioned"
means.

## Why it purges the enrollment (and keeps the pairing)

A bench device has enrolled before, so the fleet-manager already knows its
`hw_serial` and would take the *reflash* path — a different code path with a
deliberate manual step (`/enrollments/{hw_serial}/reflash-resync`). Purging the
enrollment row and **keeping the pairing** reproduces production exactly: the
label was scanned before the device ever booted, and the release fires by itself.

Pass `--keep-enrollment` to test the reflash path instead.

## Where it runs

Not on a GitHub runner — it needs the card, the MUX and the power plug. It runs
wherever ssh reaches both the bench and the fleet-manager host; today that is
the laptop or remote0. Transports are env-overridable:

| env | default | what |
|---|---|---|
| `BENCH_SSH` | `remote1` | MUX + `uhubctl` + serial console |
| `FM_SSH` | `ga-newhost` | fleet-manager API (the mesh lives inside its container, so the API is reached on the host's loopback) |
| `BUILDER_SSH` / `BUILDER_CT` | `homes4` / `107` | the builder LXC, for `--from-builder` |
| `PLUG` / `HUB` / `HUB_PORT` / `SERIAL_DEV` | `13` / `2-1.3.3` / `1` / `/dev/a16-port13` | K31 on remote1 |

`uhubctl -l 2-1.3.3` resolves to the paired USB2 hub (`1-1.3.3`) — the A16
exposes itself on both buses, and the two documented spellings are the same
physical port. Verified by cutting power and watching which device disappeared.

## Proving the gate itself

`selftest.sh` runs the `--verify-only` path against the four fixtures and
asserts the **exit code**, because that is what a caller acts on. It is wired
into `lint.yml` next to the phase-invariant selftest, so both run on every PR.

A gate that cannot fail is indistinguishable from one that works. The
phase-invariant checks were counter-checked by injection: relaxing PROV-08's
`url_prefix` condition makes the selftest report
`must-fail-no-identity/PROV-08 → pass (expected fail)` — the named guard, not
merely "something failed".

## Not covered yet

- **`external_url` / `internal_url`** — converge resolves `external_url` and
  records it in the job output but never applies it to Core. Nothing to assert
  until it is wired.
- **Stale NetBird peers** — a reflash mints a new peer and leaves the old one;
  K31 carries six named `KIB-SON-00000031`. The gate checks that the *current*
  mesh IP is the promoted one, which is the part that affects reachability.
- **The tenant wizard end to end** — the gate stops at "the wizard is armed with
  a PIN"; walking the browser flow stays with the app E2E suite.
