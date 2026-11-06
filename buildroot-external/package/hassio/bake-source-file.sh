#!/bin/sh
# bake-source-file.sh <ga_release> <channel>
#
# Prints the stem of the haos-version file the BAKE reads its component set from
# (Odoo #1610). The ONLY definition of that rule: hassio.mk (patch 0134), the
# ga-ops channel guard, gen_expected.sh and scan-cves.sh all call this script.
#
#   channel stable + release BOSv1.6.N-rcM  ->  rc        (line/1.6/rc.json: the candidate set)
#   anything else                           ->  <channel> (finals bake the proven stable.json;
#                                                          beta/dev channels are unchanged)
#
# What the image POLLS is not decided here: /etc/ga-version-url and updater.json
# keep naming the stable line, so a device never reads rc.json. An rc image's
# components may therefore be newer than stable.json until the PROMOTE step.
# Empty release (a developer `make`) falls through to the channel.
set -eu
[ "$#" -eq 2 ] || { echo "usage: $0 <ga_release> <channel>" >&2; exit 2; }
rel=$1 chan=$2
case "$chan" in stable|beta|dev) ;; *) echo "bake-source-file: unknown channel '$chan'" >&2; exit 2 ;; esac
if [ "$chan" = stable ] && printf '%s\n' "$rel" | grep -Eq '^BOSv1\.6\.[0-9]+-rc[0-9]+$'; then
  echo rc
  exit 0
fi
echo "$chan"
