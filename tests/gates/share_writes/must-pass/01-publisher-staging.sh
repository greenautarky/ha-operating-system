#!/bin/sh
# ga-share-publish's own shape: redirect into the host-only staging dir, rename.
target="${1:?target}"
stage_dir="${GA_SHARE_STAGE_DIR:-/mnt/data/.ga-share-stage}"
tmp="$stage_dir/.pub.$$.$(basename "$target")"
cat > "$tmp" || exit 1
[ -L "$target" ] && rm -f "$target"
mv -f -T "$tmp" "$target"
