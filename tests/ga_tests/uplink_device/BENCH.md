# Uplink bench procedure (Odoo #2112)

The automatic suite `uplink_device` proves the ladder and the OpenStick auto-connect are
installed, firing, and quiet on a healthy device. The scenarios below need a real dongle
or a controllable Wi-Fi and are run BY HAND on the bench device (K31 on remote1: iHost,
Ethernet port on the A16 hub, OpenStick on a hub port). Not during a soak. Each scenario
names what to do, what to watch, and the pass condition. Record the output in the PR or
the Odoo ticket; "observed working in <env> on <date>" is the only done.

Preparation (all scenarios):

    # on the device
    journalctl -f -t ga-uplink-ladder -t ga-openstick &
    watch -n5 'cat /mnt/data/supervisor/share/ga-uplink.json; nmcli -t -f NAME,DEVICE connection show --active'

Restore after every scenario: stick unplugged or powered, install Wi-Fi/Ethernet back, then
`rm -f /mnt/data/.ga-openstick-backoff /mnt/data/.ga-openstick-cooldown` and
`nmcli connection delete openstick-auto`.

## B1 - stick Wi-Fi up, SIM without data (the K31 2026-11-17 case, OS #1103)

1. Device on the install Wi-Fi (full). Power a stick whose SIM has no data service.
2. Wait for the 5-min `ga-openstick-autoconnect.timer`.
3. Expect, in order: a join of `GA-xxxx`, NM verdict `limited`, then
   `BARRED GA-xxxx for 1800s (failure 1 in a row ...)` at WARNING, profile deleted, device
   back on the install Wi-Fi. `/mnt/data/.ga-openstick-backoff` holds `GA-xxxx<TAB>1<TAB><epoch+1800>`.
4. Watch 40 min: exactly ONE join in the first 30 min (before #1103 the script re-joined every ~10 min,
   ~30 s outage each). After 30 min one retry, then `BARRED ... 7200s (failure 2 ...)`.
5. Pass: 1 join per bar window, never more; the working uplink was dropped only during the
   join itself.

## B2 - the bar is lifted when the stick is the only way out

1. As B1, then disconnect the install Wi-Fi/Ethernet (unplug / power the AP).
2. Expect at the next tick `bar on GA-xxxx (...s left) LIFTED - no other uplink is full` and the
   stick joined and KEPT even though NM says `limited` (`KEEPING it ... no back-off`), the ladder
   status `last_rung: true, searching: true`.
3. Pass: the device holds the stick connection instead of going link-less; no `connection delete`.

## B3 - a stick with working data clears the bar

1. Barred SSID from B1, then insert a SIM with data into the same stick (same `GA-xxxx`).
2. Expect, once NM says `full` on it: `UNBARRED GA-xxxx - it carries internet again`, the entry
   gone from the back-off file.

## B4 - ladder rescans before it calls the last rung (OS #1097)

1. Device on a dead dongle Wi-Fi (no WAN), bench Wi-Fi switched OFF, then switch it ON while the
   device is offline.
2. Expect within 3 ticks (6 min): `no spare uplink in the scan cache - forcing a Wi-Fi rescan`,
   then `uplink candidate '<bench Wi-Fi>' is a usable spare`, `switched ... -> ...`, and on the
   next tick `candidate ... verified full`.
3. `ga-uplink.json` during the wait: `searching: true`, `last_rescan` set; after recovery
   `searching: false`.
4. Pass: the device finds the Wi-Fi that appeared AFTER the ladder first judged the dongle the
   last rung (the 2026-11-16 K31 failure: hours on a dead dongle with the bench Wi-Fi in range).

## B5 - a candidate that is not full is not retried in a loop

1. Offer a second Wi-Fi without internet while on a dead rung.
2. Expect one `switched`, then `candidate ... is not full either - fell back to previous ...;
   barred for 600s`. No second switch to it within 10 min.
