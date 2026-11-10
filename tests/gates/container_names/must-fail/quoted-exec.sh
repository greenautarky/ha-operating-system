#!/bin/sh
opts() { docker exec "addon_99f1cad4_$1" cat /data/options.json; }
