#!/usr/bin/env bash
# go-modbump.sh GO_BIN SRCDIR FLOORS_MK SUMS_FILE [MODFILE]
#
# Lifts vendored Go modules to the floors in buildroot-external/go-modfloor.mk
# inside an extracted package tree (a Buildroot POST_PATCH hook; see that file).
#   - modules the package does not use are skipped, never added
#   - modules already at or above the floor are kept
#   - the floor releases' content hashes come from SUMS_FILE (go.sum format) and
#     are written to go.sum / vendor.sum BEFORE `go get`, so a download that
#     differs from the pin fails instead of being trusted
#   - afterwards every floored module present must be >= its floor, else exit 1
# Needs network (GOPROXY) unless GOMODCACHE already holds the modules.
set -euo pipefail

GO="${1:?go binary}" SRC="${2:?source dir}" FLOORS="${3:?floors mk}" SUMS="${4:?sums file}" MODFILE="${5:-}"
[[ -x "$GO" ]] || { echo "go-modbump: FATAL: $GO is not executable" >&2; exit 1; }
[[ -f "$FLOORS" && -f "$SUMS" ]] || { echo "go-modbump: FATAL: floors/sums file missing" >&2; exit 1; }
cd "$SRC"

mapfile -t FL < <(sed -n -E 's/^GA_GO_MODFLOOR[[:space:]]*\+?=[[:space:]]*([^[:space:]@]+@v[0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$/\1/p' "$FLOORS")
(( ${#FL[@]} > 0 )) || { echo "go-modbump: FATAL: no GA_GO_MODFLOOR lines in $FLOORS" >&2; exit 1; }

export GOTOOLCHAIN=local GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}" GOFLAGS="-mod=mod -modcacherw${MODFILE:+ -modfile=$MODFILE}"
SUMFILE="go.sum"
[[ -n "$MODFILE" ]] && SUMFILE="${MODFILE%.mod}.sum"
MODF="${MODFILE:-go.mod}"
[[ -f "$MODF" ]] || { echo "go-modbump: FATAL: $SRC/$MODF not found" >&2; exit 1; }

# 1. pin the floor releases
touch "$SUMFILE"
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  key="${line%% h1:*}"
  grep -qxF "$key" <(awk '{print $1" "$2}' "$SUMFILE") || printf '%s\n' "$line" >> "$SUMFILE"
done < "$SUMS"

cur() { "$GO" list -m -f '{{.Version}}' "$1" 2>/dev/null || true; }
lt()  { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "${1#v}" "${2#v}" | sort -V | head -n1)" == "${1#v}" ]]; }

# 2. which floored modules are below their floor?
GET=()
for f in "${FL[@]}"; do
  mod="${f%@*}" fv="${f#*@}" cv="$(cur "$mod")"
  if [[ -z "$cv" ]]; then echo "go-modbump: $mod not in the module graph of $SRC - skipped"; continue; fi
  if lt "$cv" "$fv"; then echo "go-modbump: $mod $cv -> $fv"; GET+=("$f"); else echo "go-modbump: $mod $cv >= floor $fv - kept"; fi
done

# 3. lift and re-vendor
if (( ${#GET[@]} > 0 )); then
  "$GO" get "${GET[@]}"
  "$GO" mod vendor
fi

# 4. fail closed if anything is still below its floor
bad=0
for f in "${FL[@]}"; do
  mod="${f%@*}" fv="${f#*@}" cv="$(cur "$mod")"
  [[ -z "$cv" ]] && continue
  if lt "$cv" "$fv"; then echo "go-modbump: FATAL: $mod is $cv, floor $fv" >&2; bad=1; fi
done
exit "$bad"
