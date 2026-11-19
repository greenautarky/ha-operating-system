# ga-rauc-install status file — schema 1 (Odoo #2136)

The host's `ga-rauc-install` writes `ga-rauc-install.status` into ga_manager's data
directory (`/data/ga-rauc-install.status` inside the add-on), replaced atomically.
These files are the SEAM fixtures: `tests/ga_tests/ota_resume` asserts that what the
real installer writes has exactly these keys and types (OTAR-12); ga_manager's reader
tests read the same files.

| key | type | meaning |
|---|---|---|
| schema | int | 1 |
| version, ga_release | string | the accepted request (`ga_release` may be "") |
| phase | string | queued, downloading, retrying, verifying, installing, rebooting, failed |
| bytes, total | int or null | bytes on disk / full size; null when unknown |
| attempt, max_attempts | int | the current fetch attempt and the limit |
| next_retry_at | int or null | epoch seconds of the next attempt while `retrying` |
| error | string | the last failure, "" when none |
| updated | int | epoch seconds of this write |

`rebooting` and `failed` are terminal for one request. A missing file means a host
without this feature (before 1.6.2) — the reader must then keep today's behaviour.
