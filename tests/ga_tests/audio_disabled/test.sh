#!/bin/sh
# Audio capture disabled verification - runs ON the device
#
# GDPR evidence test. GA BOS ships with the Linux sound subsystem compiled
# OUT (`# CONFIG_SOUND is not set`), so no audio capture path exists at all:
# no ALSA character devices, no snd modules to load, and PulseAudio comes up
# with zero cards. This suite asserts that property stays true.
#
# Why this needs a test: the BASE kernel config
# (buildroot-ihost/board/sonoff/kernel-rockchip.config) explicitly ENABLES
# sound, including CONFIG_SND_SOC_ROCKCHIP_PDM (the digital-microphone
# controller). It is off only because board/sonoff/ihost/kernel.config is
# merged LAST and overrides it. Reordering the fragment list in
# BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES would silently re-enable capture.
#
# Paired with the AUD-* checks in tests/ga_tests/run_build_tests.sh, which
# gate the same property at build time before an image ever ships.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Audio Disabled"

# --- Kernel: sound subsystem absent ---

run_test "AUD-01" "no ALSA character devices (/dev/snd absent)" \
  "! test -e /dev/snd"

run_test "AUD-02" "no ALSA procfs (/proc/asound absent)" \
  "! test -e /proc/asound"

# AUD-03/04 read the RUNNING kernel's own config. Gate them on the evidence
# actually being available: without /proc/config.gz, `zcat` fails, grep finds
# nothing, and a naive `! grep -q ...` would PASS while proving nothing —
# fail-open, the same trap as a green CVE scan with zero coverage. Skip
# loudly instead, so a missing evidence source is visible rather than silent.
if [ -e /proc/config.gz ]; then
  run_test "AUD-03" "running kernel has no SND symbol enabled" \
    "! { zcat /proc/config.gz | grep -q '^CONFIG_SND'; }"

  run_test "AUD-04" "running kernel built with CONFIG_SOUND off" \
    "zcat /proc/config.gz | grep -q '^# CONFIG_SOUND is not set'"
else
  skip_test "AUD-03" "running kernel has no SND symbol enabled" \
    "/proc/config.gz absent — kernel-config evidence unavailable"
  skip_test "AUD-04" "running kernel built with CONFIG_SOUND off" \
    "/proc/config.gz absent — kernel-config evidence unavailable"
fi

# --- Modules: capture cannot be loaded back in ---

run_test "AUD-05" "no snd modules loaded" \
  "! lsmod 2>/dev/null | grep -qi '^snd'"

# The strong guarantee: absent from the module tree entirely, so no
# `modprobe snd_usb_audio` (USB mic dongle) can resurrect a capture path.
run_test "AUD-06" "no snd modules on disk (modprobe cannot restore capture)" \
  "! find /lib/modules /usr/lib/modules -name 'snd*' 2>/dev/null | grep -q ."

run_test "AUD-07" "no audio platform driver bound" \
  "! ls /sys/bus/platform/drivers/ 2>/dev/null | grep -qiE 'i2s|pdm|snd|codec'"

# --- Leftover playback unit stays masked ---

run_test "AUD-08" "audio-setup.service is masked" \
  "systemctl is-enabled audio-setup.service 2>/dev/null | grep -q '^masked$'"

# --- Seam: what an addon would actually see ---
# hassio_audio (the Supervisor PulseAudio plugin) is the boundary any addon
# with `audio: true` talks to -- assist_microphone among them. Test AT that
# seam, not just at the kernel.

if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^hassio_audio$'; then
  run_test "AUD-09" "PulseAudio plugin has no sound card" \
    "test -z \"\$(docker exec hassio_audio pactl list cards short 2>/dev/null)\""

  # auto_null.monitor is the monitor of PulseAudio's fallback null-sink; it
  # records silence, not audio. Any OTHER source would be a real capture path.
  run_test "AUD-10" "PulseAudio plugin exposes no capture source" \
    "test -z \"\$(docker exec hassio_audio pactl list sources short 2>/dev/null | grep -v '\.monitor')\""

  run_test "AUD-11" "no /dev/snd inside the PulseAudio plugin container" \
    "! docker exec hassio_audio test -e /dev/snd"
else
  skip_test "AUD-09" "PulseAudio plugin has no sound card" "hassio_audio not running"
  skip_test "AUD-10" "PulseAudio plugin exposes no capture source" "hassio_audio not running"
  skip_test "AUD-11" "no /dev/snd inside the PulseAudio plugin container" "hassio_audio not running"
fi

# --- Audit evidence availability (informational) ---

warn_test "AUD-12" "/proc/config.gz available as on-device audit evidence" \
  "test -e /proc/config.gz"

suite_end
