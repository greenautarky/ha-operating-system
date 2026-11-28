#!/bin/sh
# bake-source-file.sh <ga_release> <channel>
#
# Prints the stem of the haos-version file the BAKE reads its component set from
# (Odoo #1610). The ONLY definition of that rule: hassio.mk (patch 0134), the
# ga-ops channel guard, gen_expected.sh and scan-cves.sh all call this script.
#
#   channel stable + release BOSv1.6.N-rcM  ->  rc        (line/1.6/rc.json: the candidate set)
#   channel stable + release BOSv1.6.N      ->  rc        (a final bakes the SAME file as its gated rc;
#                                                          Gate A keeps the final equal to that rc)
#   anything else                           ->  <channel> (beta/dev channels, other lines unchanged)
#
# Why a 1.6 final reads rc.json (Thomas 2026-11-26, option 1a): it used to bake the device-facing
# stable.json, so a final could only be baked after stable.json was promoted, i.e. after every device
# of the line had been offered the new Supervisor. A newer Supervisor in stable.json blocks add-on,
# store and plugin updates on every device still on the older one until it is updated (measured on
# K31 2026-11-26). Baking the final from rc.json leaves stable.json, and the field, untouched.
#
# What the image POLLS is not decided here: /etc/ga-version-url and updater.json
# keep naming the stable line, so a device never reads rc.json. An rc image's
# components may therefore be newer than stable.json until the PROMOTE step.
# Empty release (a developer `make`) falls through to the channel.
set -eu
[ "$#" -eq 2 ] || { echo "usage: $0 <ga_release> <channel>" >&2; exit 2; }
rel=$1 chan=$2
case "$chan" in stable|beta|dev) ;; *) echo "bake-source-file: unknown channel '$chan'" >&2; exit 2 ;; esac
if [ "$chan" = stable ] && printf '%s\n' "$rel" | grep -Eq '^BOSv1\.6\.[0-9]+(-rc[0-9]+)?$'; then
  echo rc
  exit 0
fi
echo "$chan"
