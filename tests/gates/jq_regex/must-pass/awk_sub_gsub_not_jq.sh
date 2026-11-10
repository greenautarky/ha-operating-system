#!/bin/sh
# awk sub/gsub are NOT jq regex builtins; one real regex-free jq program keeps the file counted.
echo "$x" | awk '{ sub(/a/, "b"); gsub(/c/, "d"); print }'
jq -r '.a | split(",") | map(ascii_downcase) | join(" ")' f
command -v jq >/dev/null 2>&1 || exit 1
