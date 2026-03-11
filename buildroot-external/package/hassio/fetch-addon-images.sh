#!/usr/bin/env bash
# Fetch pre-baked addon images listed in addon-images.json.
# Resolves {arch} placeholder and calls fetch-container-image.sh in direct mode.
set -eu -o pipefail

arch=$1
machine=$2
addon_json=$3
dl_dir=$4
dst_dir=$5

script_dir="$(dirname "$0")"

for addon in $(jq -r '.addons | keys[]' "$addon_json"); do
	image=$(jq -r --arg a "$addon" --arg arch "$arch" \
		'.addons[$a].image | sub("{arch}"; $arch)' "$addon_json")
	version=$(jq -r --arg a "$addon" '.addons[$a].version' "$addon_json")

	echo ">>> Addon: ${addon} -> ${image}:${version}"
	"$script_dir/fetch-container-image.sh" \
		"$arch" "$machine" "$image" "direct:$version" "$dl_dir" "$dst_dir"
done
