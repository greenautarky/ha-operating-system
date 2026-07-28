# Audio Capture Disabled Tests

## Purpose
Prove that a GA BOS device has **no audio capture path at all** — the evidence
behind the GDPR statement that these devices cannot make audio recordings.

This is a stronger property than a policy or a disabled service: the Linux sound
subsystem is compiled **out** of the kernel (`# CONFIG_SOUND is not set`), so
there is nothing to enable, configure, or `modprobe` back.

## Why this needs a regression guard

The **base** kernel config for the board
(`buildroot-ihost/board/sonoff/kernel-rockchip.config`) explicitly **enables**
sound:

```
CONFIG_SOUND=y
CONFIG_SND=y
CONFIG_SND_SOC_ROCKCHIP_I2S=y
CONFIG_SND_SOC_ROCKCHIP_PDM=y      # digital-microphone controller
CONFIG_SND_SOC_RK817=y
```

It ends up off only because `board/sonoff/ihost/kernel.config` is merged **last**
in `BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES` and overrides it. Two plausible
changes re-enable microphone capture silently:

1. reordering the fragment list, or
2. dropping/renaming the ihost fragment.

Neither would break any other test. Hence AUD-*.

The device tree still contains `i2s@ff800000` and an `rk809-sound` card node —
they are inert (no driver exists to bind them), but their presence means the
hardware description alone is **not** evidence of absence. Only the kernel
config and the runtime checks below are.

## Prerequisites
- Device booted on GA BOS (post-build or post-OTA)
- Test harness available (`lib/test_helpers.sh`)
- `hassio_audio` running for the seam tests (AUD-09..11); skipped otherwise

## Tests

### AUD-01: no ALSA character devices
- **Command**: `! test -e /dev/snd`
- **Expected**: `/dev/snd` absent — no ALSA device nodes exist
- **Catches**: sound subsystem re-enabled in the kernel

### AUD-02: no ALSA procfs
- **Command**: `! test -e /proc/asound`
- **Expected**: `/proc/asound` absent — the ALSA core never registered

### AUD-03: running kernel has no SND symbol enabled
- **Command**: `! { zcat /proc/config.gz | grep -q '^CONFIG_SND'; }`
- **Expected**: zero enabled `CONFIG_SND*` symbols
- **Note**: asserting `# CONFIG_SND is not set` would be wrong — with
  `CONFIG_SOUND` off, Kconfig omits the `CONFIG_SND` line entirely rather than
  emitting an "is not set" comment. Absence of any enabled symbol is the
  correct assertion. This also covers `CONFIG_SND_USB_AUDIO`, i.e. a USB
  microphone dongle has no driver either.

### AUD-04: running kernel built with CONFIG_SOUND off
- **Command**: `zcat /proc/config.gz | grep -q '^# CONFIG_SOUND is not set'`
- **Expected**: the running kernel positively declares sound disabled
- **Catches**: an OTA that shipped a kernel from a different fragment order

### AUD-05: no snd modules loaded
- **Command**: `! lsmod | grep -qi '^snd'`
- **Expected**: no sound module resident

### AUD-06: no snd modules on disk
- **Command**: `! find /lib/modules /usr/lib/modules -name 'snd*' | grep -q .`
- **Expected**: module tree contains no `snd*` object
- **Why it matters**: this is the difference between "off" and "impossible".
  With no module on disk, root cannot `modprobe` a capture path back — not for
  the onboard codec and not for a plugged-in USB microphone.

### AUD-07: no audio platform driver bound
- **Command**: `! ls /sys/bus/platform/drivers/ | grep -qiE 'i2s|pdm|snd|codec'`
- **Expected**: the DT nodes `i2s@ff800000` / `rk809-sound` have no driver bound

### AUD-08: audio-setup.service is masked
- **Command**: `systemctl is-enabled audio-setup.service | grep -q '^masked$'`
- **Expected**: `masked` — the leftover playback unit stays inert
- **Note**: masked at build time via a rootfs-overlay symlink to `/dev/null`
  (runtime `ln` fails on the read-only rootfs). Replaces the old CFG-25, which
  matched a *comment* in `ga-overlay-init` and could never fail.

### AUD-09: PulseAudio plugin has no sound card
- **Command**: `test -z "$(docker exec hassio_audio pactl list cards short)"`
- **Expected**: empty card list
- **Seam**: `hassio_audio` is the Supervisor's PulseAudio plugin — the boundary
  every addon with `audio: true` talks to (the HA store ships
  `assist_microphone`, `music_assistant`, `vlc`, …). Testing the kernel alone
  would not prove what an addon actually sees.

### AUD-10: PulseAudio plugin exposes no capture source
- **Command**: `test -z "$(docker exec hassio_audio pactl list sources short | grep -v '\.monitor')"`
- **Expected**: no non-monitor source
- **Note**: PulseAudio always synthesises `auto_null` plus its
  `auto_null.monitor` when no card exists. A monitor of a null sink records
  silence, so monitors are excluded; **any** other source would be a real
  microphone.

### AUD-11: no /dev/snd inside the PulseAudio plugin container
- **Command**: `! docker exec hassio_audio test -e /dev/snd`
- **Expected**: absent — nothing to bind-mount onward into an addon

### AUD-12: /proc/config.gz available as audit evidence (warn only)
- **Command**: `test -e /proc/config.gz`
- **Expected**: present, so the kernel-config proof is reproducible on any
  device during an audit
- **Severity**: WARN — losing it weakens the evidence trail but does not itself
  enable capture

## Scope limits (read before citing this suite in a compliance document)

- The property is proven **per device, for GA BOS**. Fleet peers running stock
  HAOS are **not** covered — stock HAOS ships sound enabled.
- AUD-* proves no *kernel-level* capture path. It does not speak to audio
  arriving over the network from other equipment.
- Whether a microphone is physically present on the board is **not** asserted
  here; the software claim holds either way.

## Related
- Build-time counterpart in `tests/ga_tests/run_build_tests.sh`, which gates the
  image before it ever ships:
  - **AUD-01** `# CONFIG_SOUND is not set` in the built kernel config
  - **AUD-02** no enabled `CONFIG_SND*` symbol
  - **AUD-03** `CONFIG_SND_SOC_ROCKCHIP_PDM` not built
  - **AUD-04** no `snd*` object in the target module tree
  - **AUD-05** `audio-setup.service` masked (symlink → `/dev/null`)
