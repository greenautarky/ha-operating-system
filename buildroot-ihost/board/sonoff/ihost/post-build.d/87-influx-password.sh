#!/bin/bash
# Inject InfluxDB password into telegraf.conf at build time.
# Password is stored in secrets/influx-password (gitignored).
set -e

TARGET_DIR="$1"
CONF_FILE="${TARGET_DIR}/etc/telegraf/telegraf.conf"
SECRET_FILE="/build/secrets/influx-password"

if [ ! -f "$CONF_FILE" ]; then
  echo "influx-password: telegraf.conf not found, skipping"
  exit 0
fi

if [ ! -f "$SECRET_FILE" ]; then
  echo "WARNING: $SECRET_FILE not found — Telegraf will not authenticate to InfluxDB"
  echo "         Create secrets/influx-password with the device_writer password"
  exit 0
fi

PW=$(cat "$SECRET_FILE" | tr -d '\n')
sed -i "s|\${INFLUX_PASSWORD}|${PW}|" "$CONF_FILE"
echo "influx-password: injected InfluxDB password into telegraf.conf"
