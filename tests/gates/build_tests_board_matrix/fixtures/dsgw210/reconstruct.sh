#!/bin/bash
# Applied by make-fixture.sh after unpacking. The DSGW-210 fixture was captured from the last DSGW bake
# whose artefact is still on the builder (BOSv1.6.0-dev4, 2026-11-06 14:21), which was built BEFORE
# #987 put iw into the image (that bake's own WIFI-09 was red). The one thing #987 changed in the
# image is this file; every other file is the real bake's.
OUT="$1"
: > "$OUT/target/usr/sbin/iw"; chmod 755 "$OUT/target/usr/sbin/iw"; touch -d 2026-01-01 "$OUT/target/usr/sbin/iw"
