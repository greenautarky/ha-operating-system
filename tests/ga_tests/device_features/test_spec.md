# device_features — what it asks, and why the other two suites do not

`os_integrity` asks *is the flashed artefact what master declared*.
`addons_running` asks *is every add-on up and answering*.

Neither notices a feature that was built, pinned, baked — and then does nothing.
That is the failure this project keeps paying for:

* a component **placed** into Home Assistant's config but never **loaded**
* a metric written to a path nothing collects
* a security fix published, and pinned by nobody, so no device ever got it

This suite is the third question: **does the feature surface actually do
something on the device that ships it.**

## Rules it follows

**Every assertion was measured before it was written.** Nothing here is
aspirational. When this suite was created (K31, BOSv1.3.0-rc7, 2026-08-24) all
21 checks were run against the real device first, and only then committed.

**Staged, placed and loaded are three different states.** FEAT-04/05/06 assert
each separately, because the gap between placed and loaded is exactly where a
component silently does nothing and every other check stays green.

**Assert the condition, not the state, where a human decision is involved.**
FEAT-10 asserts that telegraf is *gated on* a consent marker — not that telegraf
is running. A suite demanding "active" would push people to defeat the gate.

**Never assert on a secret's value.** FEAT-11 asserts the *shape* — that no
password-bearing key carries a value — and FEAT-01 asserts a file *mode*.

**A loop over zero items is a broken generator.** FEAT-98 fails if the component
list is empty, so a staging path that stopped producing anything cannot pass as
a clean device.

## Red proof

Run 2026-08-24 on K31 by injecting three defects covering the three assertion
styles (a mode, a file's presence, a count), then restoring:

```
chmod 644 /mnt/data/supervisor/share/influxdb_password.yaml
mv  …/custom_components/ga_heating/manifest.json  aside
mv  …/share/telegraf/ga-heating.influx            aside

  FAIL  FEAT-01: influx /share secret is 0600, not world-readable
  FAIL  FEAT-05/ga_heating: component placed into HA Core's config
  FAIL  FEAT-09: more than one writer drops into the directory
  18 passed, 3 failed
```

Exactly the three injected defects went red and nothing else, which is the point
— a suite where *something* fails proves far less than one where the specific
guard under test fails.

## FEAT-09 is what gives FEAT-08 its meaning

With a single writer, a directory glob and a hardcoded filename behave
identically, so FEAT-08 alone could pass on a configuration that is one writer
away from silently dropping data. FEAT-09 asserts that a second writer really is
dropping files, which is the condition under which the two differ.
