#!/usr/bin/env bash
set -e

build_dir=$1
dst_dir=$2
channel=$3
docker_version=$4
data_image_size=$5

data_img="${dst_dir}/data.ext4"

# Make image
rm -f "${data_img}"
truncate --size="${data_image_size}" "${data_img}"
mkfs.ext4 -L "hassos-data" -E lazy_itable_init=0,lazy_journal_init=0 "${data_img}"

# Mount / init file structs
mkdir -p "${build_dir}/data/"
sudo mount -o loop,discard "${data_img}" "${build_dir}/data/"

# Registry credentials for the DinD fallback path.
#
# dind-import-containers.sh loads the pre-fetched image tarballs, but falls
# back to `skopeo` pulling by digest when a tarball is unreadable or in an
# unrecognised format. That fallback runs INSIDE this container, which does not
# inherit the host's registry login — and since 2026-07-29 the ga_manager
# packages are private, so an unauthenticated fallback would fail. It would
# fail at the worst moment too: the fallback only triggers on an already-broken
# build, and a second, unrelated-looking error there costs real debugging time.
#
# Mounted read-only, and only when it exists (a builder without a login still
# works for the all-public case).
docker_auth_mount=""
if [ -f "${HOME:-/root}/.docker/config.json" ]; then
	docker_auth_mount="-v ${HOME:-/root}/.docker/config.json:/root/.docker/config.json:ro"
fi

# Use official Docker in Docker images
# We use the same version as Buildroot is using to ensure best compatibility
# shellcheck disable=SC2086 # docker_auth_mount is intentionally word-split
container=$(docker run --privileged -e DOCKER_TLS_CERTDIR="" \
	-v "${build_dir}/data/":/data \
	-v "${build_dir}/data/docker/":/var/lib/docker \
	-v "${build_dir}":/build \
	${docker_auth_mount} \
	-d "docker:${docker_version}-dind" --storage-driver overlay2)

docker exec "${container}" sh /build/dind-import-containers.sh "${channel}"

docker stop "${container}"

# Unmount data image
sudo umount "${build_dir}/data/"
