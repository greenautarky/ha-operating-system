#!/bin/sh
# DSGW-210 boot-time radio GPIO setup (ported from the vendor's
# /usr/bin/export_zigbee_zwave_ble_gpio.sh).
#
# Exports the radio reset+power GPIOs via sysfs and drives them HIGH so
# Zigbee + Bluetooth (and optionally Z-Wave) come up at boot. Idempotent
# — re-running it is a no-op if pins are already exported.
#
# Note: the vendor script's "zigbee"/"ble" labels are swapped relative to
# the chip on each ttyUSB. The GPIO numbers themselves are right, and the
# operation (drive HIGH at boot) is identical for both radios, so the same
# GPIO set is kept. The comments below use the corrected mapping.

set -e

export_high() {
	n=$1
	if [ ! -e /sys/class/gpio/gpio$n/value ]; then
		echo "$n" > /sys/class/gpio/export 2>/dev/null || true
	fi
	if [ -e /sys/class/gpio/gpio$n/direction ]; then
		echo out > /sys/class/gpio/gpio$n/direction 2>/dev/null || true
		echo 1 > /sys/class/gpio/gpio$n/value 2>/dev/null || true
	fi
}

# Bluetooth (SiLabs EFR32 BG NCP, /dev/bluetooth, hub port 4-1.2)
# The vendor script labels these "zigbee"; they are the BT chip.
export_high 80   # BT reset deassert (active-high run)
export_high 101  # BT power enable

# Zigbee (SiLabs EFR32 EZSP / EmberZNet, /dev/zigbee, hub port 4-1.3)
# The vendor script labels these "ble"; they are the Zigbee chip.
export_high 81   # Zigbee reset deassert (active-high run)
export_high 67   # Zigbee power enable (gpio2_PA3). The chip has its own
                 # VBAT rail and works without this pad reading high;
                 # keeping the export mirrors the vendor script and is
                 # harmless.

# Z-Wave (SiLabs ZGM130S — /dev/ttyS1, SoC UART1, not USB)
export_high 79   # Z-Wave reset deassert
export_high 82   # Z-Wave power enable

# NB: the front push button is NOT handled here (see the gpio-keys and
# adc-keys nodes in the device tree).

echo "dsgw210-radio-gpio: exported zigbee/bt/zwave reset+power lines"
