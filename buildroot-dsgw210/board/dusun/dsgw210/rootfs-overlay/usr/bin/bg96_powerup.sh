#!/bin/sh

export_reset_power_gpio() {
	n=$1
	[ ! -e /sys/class/gpio/gpio$n/value ] && {
		echo $n > /sys/class/gpio/export
		echo out > /sys/class/gpio/gpio$n/direction
	}
	echo 1 > /sys/class/gpio/gpio$n/value
}

export_gpio_low() {
	n=$1
	[ ! -e /sys/class/gpio/gpio$n/value ] && {
		echo $n > /sys/class/gpio/export
		echo out > /sys/class/gpio/gpio$n/direction
	}
	echo 0 > /sys/class/gpio/gpio$n/value
}

# bg96
# power off
if [ $1 = 'off' ];then
export_gpio_low         54  # powerctl
export_gpio_low         53  # powerkey
export_reset_power_gpio 58  # reset
elif [ $1 = 'on' ];then
# power on
export_reset_power_gpio 54  # powerctl
export_reset_power_gpio 53  # powerkey
export_gpio_low         58  # reset, this is weird
fi


