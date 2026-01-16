#!/bin/sh
set -eu

# Buildroot hassio dind image importer (robust)
# - Loads docker-archive tars even when manifest.json is under a prefix directory
# - Loads legacy docker save tars (repositories) even under a prefix
# - Loads OCI layout tars even under a prefix (oci-layout or index.json+blobs)
# - Imports rootfs tars (docker export style) if extracted content looks like a filesystem
# - If a tar is unreadable/invalid or unrecognized, falls back to pulling by digest via skopeo
#   IMPORTANT: skopeo docker:// transport does NOT support ":tag@sha256:...". We pull digest-only:
#     docker://repo@sha256:...  -> docker-daemon:repo:tag
#
# Env:
#   ONLINE_FALLBACK=1          enable skopeo pull fallback (default 1)
#   SKOPEO_CREDS="USER:TOKEN"  optional GHCR auth for skopeo
#   IMAGES_DIR=...             override image tar directory detection
#
# Notes:
# - Designed for Alpine-based docker:dind environment (apk available).
# - This script is intended to be invoked by Buildroot hassio package step.

SCRIPT_ID="dind-import-containers.sh/2025-12-23-06"

channel="${1:-stable}"
channel="${channel#\"}"; channel="${channel%\"}"

APPARMOR_URL="${APPARMOR_URL:-https://version.home-assistant.io/apparmor.txt}"

ONLINE_FALLBACK="${ONLINE_FALLBACK:-1}"
SKOPEO_CREDS="${SKOPEO_CREDS:-}"

log() { echo "$SCRIPT_ID: $*"; }
die() { echo "$SCRIPT_ID: ERROR: $*" >&2; exit 1; }

log "Waiting for Docker daemon..."
while ! docker version >/dev/null 2>&1; do
  sleep 1
done

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_pkg() {
  if have_cmd apk; then
    apk add --no-cache "$@" >/dev/null 2>&1 || true
  fi
}

# --- Decompression detection by magic bytes (gzip/xz/zstd), independent of 'file' ---
magic_hex4() { dd if="$1" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n'; }

detect_reader() {
  f="$1"
  m4="$(magic_hex4 "$f")"
  case "$m4" in
    1f8b*)     ensure_pkg gzip; echo "gzip -dc" ;;
    fd377a58)  ensure_pkg xz;   echo "xz -dc" ;;
    28b52ffd)  ensure_pkg zstd; echo "zstd -dc" ;;
    *)         echo "cat" ;;
  esac
}

tar_can_list() {
  f="$1"
  r="$(detect_reader "$f")"
  if [ "$r" = "cat" ]; then
    tar -tf "$f" >/dev/null 2>&1
  else
    # shellcheck disable=SC2086
    $r "$f" 2>/dev/null | tar -tf - >/dev/null 2>&1
  fi
}

tar_extract_to() {
  f="$1"; out="$2"
  r="$(detect_reader "$f")"
  if [ "$r" = "cat" ]; then
    tar -xf "$f" -C "$out"
  else
    # shellcheck disable=SC2086
    $r "$f" 2>/dev/null | tar -xf - -C "$out"
  fi
}

# --- GHCR filename -> digest-only docker ref + tag ---
# Returns: "<registry>/<path>@sha256:<hex>|<tag>"
parse_image_ref_from_filename() {
  # Example filename:
  #   ghcr.io_home-assistant_tinker-homeassistant_2025.11.3@sha256_f800....tar
  base="$(basename "$1" .tar)"
  IFS="_"; set -- $base; unset IFS
  [ "$#" -ge 4 ] || return 1

  registry="$1"
  digest_hex="$(eval "printf '%s' \"\${$#}\"")"

  prev_idx="$(($# - 1))"
  tag_sha="$(eval "printf '%s' \"\${$prev_idx}\"")"
  case "$tag_sha" in *@sha256) : ;; *) return 1 ;; esac

  tag="${tag_sha%@sha256}"
  digest="sha256:${digest_hex}"

  path=""
  i=2
  end="$(($# - 2))"
  while [ "$i" -le "$end" ]; do
    seg="$(eval "printf '%s' \"\${$i}\"")"
    path="${path:+$path/}$seg"
    i="$(($i + 1))"
  done

  # IMPORTANT: digest-only source (no :tag) for skopeo docker:// transport
  echo "${registry}/${path}@${digest}|${tag}"
}

ensure_skopeo() {
  if have_cmd skopeo; then return 0; fi
  ensure_pkg skopeo
  have_cmd skopeo || die "skopeo not available (apk missing or install failed)."
}

skopeo_copy_docker_to_daemon() {
  ref="$1"   # registry/repo@sha256:...
  dest="$2"  # registry/repo:tag  (tag only at destination)
  ensure_skopeo

  auth=""
  if [ "$SKOPEO_CREDS" != "" ]; then
    auth="--creds $SKOPEO_CREDS"
  elif [ -f /root/.docker/config.json ]; then
    auth="--authfile /root/.docker/config.json"
  fi

  log "skopeo copy docker://$ref -> docker-daemon:$dest"
  # shellcheck disable=SC2086
  skopeo copy --retry-times 5 --insecure-policy $auth "docker://$ref" "docker-daemon:$dest" >/dev/null
}

docker_load_dir_as_tar_stream() {
  dir="$1"
  log "docker load from repacked tar stream: $dir"
  tar -C "$dir" -cf - . | docker load >/dev/null
}

docker_import_dir_as_rootfs() {
  dir="$1"
  tag="$2"
  log "docker import rootfs tar stream: $dir -> $tag"
  tar -C "$dir" -cf - . | docker import - "$tag" >/dev/null
}

pick_images_dir() {
  if [ "${IMAGES_DIR:-}" != "" ] && [ -d "$IMAGES_DIR" ] && ls "$IMAGES_DIR"/*.tar >/dev/null 2>&1; then
    echo "$IMAGES_DIR"; return 0
  fi

  for d in \
    /build/images \
    /build/build/ga_output/build/hassio-*/images \
    /build/ga_output/build/hassio-*/images \
    /build/ga_output/build/hassio-1.0.0/images \
    /build/build/ga_output/build/hassio-1.0.0/images
  do
    for dd in $d; do
      [ -d "$dd" ] || continue
      if ls "$dd"/*.tar >/dev/null 2>&1; then
        echo "$dd"; return 0
      fi
    done
  done

  found="$(find /build -maxdepth 6 -type f -name '*.tar' -path '*/hassio-*/images/*' 2>/dev/null | head -n 1 || true)"
  [ "$found" != "" ] && dirname "$found" && return 0
  return 1
}

IMAGES_DIR="$(pick_images_dir)" || die "Could not locate hassio image *.tar archives (set IMAGES_DIR)."
log "Using IMAGES_DIR=$IMAGES_DIR"
log "Loading container images..."

imported=0
for image in "$IMAGES_DIR"/*.tar; do
  [ -e "$image" ] || continue
  imported=1

  base="$(basename "$image")"

  # If not listable as tar, it might be an error response saved as .tar -> fallback to skopeo pull
  if ! tar_can_list "$image"; then
    if [ "$ONLINE_FALLBACK" = "1" ]; then
      parsed="$(parse_image_ref_from_filename "$image" || true)"
      if [ "$parsed" != "" ]; then
        ref="${parsed%|*}"      # registry/repo@sha256:...
        tag="${parsed#*|}"      # e.g. 2025.11.3
        repo="${ref%@*}"        # registry/repo
        dest="${repo}:${tag}"   # registry/repo:tag
        skopeo_copy_docker_to_daemon "$ref" "$dest"
        continue
      fi
    fi

    log "First 200 bytes (printable) of $base:"
    head -c 200 "$image" | sed 's/[^[:print:]\t]/./g' || true
    die "File is not a readable tar archive: $image"
  fi

  # Extract-and-detect (handles prefix directories)
  tmpdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap 'rm -rf "$tmpdir" >/dev/null 2>&1 || true' INT TERM EXIT

  tar_extract_to "$image" "$tmpdir"

  # 1) Docker archive: manifest.json anywhere
  m="$(find "$tmpdir" -maxdepth 8 -type f -name manifest.json | head -n 1 || true)"
  if [ "$m" != "" ]; then
    root="$(dirname "$m")"
    log "Detected docker-archive (manifest.json) in: $root (file: $base)"
    docker_load_dir_as_tar_stream "$root"
    rm -rf "$tmpdir" >/dev/null 2>&1 || true
    trap - INT TERM EXIT
    continue
  fi

  # 2) Legacy docker save: repositories anywhere
  rfile="$(find "$tmpdir" -maxdepth 8 -type f -name repositories | head -n 1 || true)"
  if [ "$rfile" != "" ]; then
    root="$(dirname "$rfile")"
    log "Detected legacy docker save (repositories) in: $root (file: $base)"
    docker_load_dir_as_tar_stream "$root"
    rm -rf "$tmpdir" >/dev/null 2>&1 || true
    trap - INT TERM EXIT
    continue
  fi

  # 3) OCI layout: oci-layout or (index.json + blobs) anywhere
  root=""
  o="$(find "$tmpdir" -maxdepth 8 -type f -name oci-layout | head -n 1 || true)"
  if [ "$o" != "" ]; then
    root="$(dirname "$o")"
  else
    idx="$(find "$tmpdir" -maxdepth 8 -type f -name index.json | head -n 1 || true)"
    if [ "$idx" != "" ]; then
      idxdir="$(dirname "$idx")"
      if find "$idxdir" -maxdepth 3 -type d -name blobs | grep -q .; then
        root="$idxdir"
        printf '{ "imageLayoutVersion": "1.0.0" }\n' > "$root/oci-layout" || true
      fi
    fi
  fi

  if [ "$root" != "" ]; then
    ensure_skopeo
    ref_local="local/oci-import:$(basename "$image" .tar)"
    log "Detected OCI layout in: $root (file: $base) -> $ref_local"
    auth=""
    if [ "$SKOPEO_CREDS" != "" ]; then
      auth="--creds $SKOPEO_CREDS"
    elif [ -f /root/.docker/config.json ]; then
      auth="--authfile /root/.docker/config.json"
    fi
    # shellcheck disable=SC2086
    skopeo copy --retry-times 5 --insecure-policy $auth "oci:$root" "docker-daemon:$ref_local" >/dev/null
    rm -rf "$tmpdir" >/dev/null 2>&1 || true
    trap - INT TERM EXIT
    continue
  fi

  # 4) Rootfs tar (docker export style): import if filesystem-like
  if find "$tmpdir" -maxdepth 2 -type d \( -name bin -o -name etc -o -name usr -o -name lib -o -name sbin \) | grep -q .; then
    tag_local="local/rootfs-import:$(basename "$image" .tar)"
    log "Detected rootfs tree in extracted content (file: $base) -> $tag_local"
    docker_import_dir_as_rootfs "$tmpdir" "$tag_local"
    rm -rf "$tmpdir" >/dev/null 2>&1 || true
    trap - INT TERM EXIT
    continue
  fi

  # 5) Online fallback for "weird but tar" cases as well
  if [ "$ONLINE_FALLBACK" = "1" ]; then
    parsed="$(parse_image_ref_from_filename "$image" || true)"
    if [ "$parsed" != "" ]; then
      ref="${parsed%|*}"      # registry/repo@sha256:...
      tag="${parsed#*|}"      # e.g. 2025.11.3
      repo="${ref%@*}"        # registry/repo
      dest="${repo}:${tag}"   # registry/repo:tag
      skopeo_copy_docker_to_daemon "$ref" "$dest"
      rm -rf "$tmpdir" >/dev/null 2>&1 || true
      trap - INT TERM EXIT
      continue
    fi
  fi

  log "Extracted top-level listing for $base:"
  (cd "$tmpdir" && find . -maxdepth 2 -print | head -n 120) || true
  die "Unknown tar content after extraction: $image"
done

[ "$imported" -eq 1 ] || die "No *.tar archives found in IMAGES_DIR=$IMAGES_DIR"

log "Loaded images (top 30):"
docker images --format '{{.Repository}}:{{.Tag}}  {{.ID}}' | head -n 30 || true

# Locate supervisor image
supervisor_id="$(docker images --filter "label=io.hass.type=supervisor" --quiet | head -n1 || true)"
if [ "$supervisor_id" = "" ]; then
  supervisor_id="$(docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' \
    | awk 'tolower($1) ~ /(hassio-)?supervisor/ {print $2; exit}')"
fi
[ "$supervisor_id" != "" ] || { docker images || true; die "Supervisor image not found after import (cannot tag)."; }

# Determine arch
arch="$(docker image inspect --format '{{ index .Config.Labels "io.hass.arch" }}' "$supervisor_id" 2>/dev/null || true)"
if [ "$arch" = "" ]; then
  case "$(uname -m)" in
    armv7l|armv7*) arch="armv7" ;;
    aarch64)       arch="aarch64" ;;
    x86_64)        arch="amd64" ;;
    *)             arch="$(uname -m)" ;;
  esac
fi

# Tag supervisor
log "Tagging supervisor image $supervisor_id as oliverc7/${arch}-hassio-supervisor:latest"
docker tag "$supervisor_id" "oliverc7/${arch}-hassio-supervisor:latest"

# AppArmor + updater metadata
mkdir -p /data/supervisor/apparmor /data/supervisor
wget -O /data/supervisor/apparmor/hassio-supervisor "$APPARMOR_URL" >/dev/null || true
printf '{ "channel": "%s" }\n' "$channel" > /data/supervisor/updater.json

log "Done. channel=$channel"
