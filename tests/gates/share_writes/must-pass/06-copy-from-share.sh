#!/bin/sh
# Copying FROM the shared directory to a host-only path.
SRC=/mnt/data/supervisor/share/example.json
cp "$SRC" /run/example.copy
mv /run/example.copy /run/example.final
