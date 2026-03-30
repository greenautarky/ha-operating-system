#!/bin/bash
# Mask audio-setup.service — iHost has no audio hardware.
# Must be done in post-build (not overlay symlink) because Buildroot's
# preset phase runs before overlays and fails on masked units.
set -e

TARGET_DIR="$1"
ln -sf /dev/null "${TARGET_DIR}/etc/systemd/system/audio-setup.service"
echo "audio-setup.service masked (no audio on iHost)"
