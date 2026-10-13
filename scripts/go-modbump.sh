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
#   - the pins must be COMPLETE: the bump pulls transitive requirements (x/crypto
#     0.57.0 -> x/sys 0.48.0, x/text 0.42.0 -> x/sync 0.23.0, ...). Buildroot's Go
#     has no go.env, so GOSUMDB is EMPTY there and `go` aborts with "verifying
#     go.mod: missing GOSUMDB" on the first module that is not in go.sum. The hook
#     therefore does not depend on the checksum database at all: GOSUMDB=off, and
#     afterwards EVERY go.sum line that is neither in the package's own go.sum nor in
#     SUMS is a FATAL "unpinned" error naming the module. Nothing is trusted on first
#     use: a download either matches a pinned (or upstream) hash or the build stops.
#   - GA_GO_MODBUMP_DISCOVER=1 is the maintenance mode: GOSUMDB=sum.golang.org (the
#     lines are verified by the checksum database), no audit failure, and every
#     unpinned line is printed as "go-modbump: PIN <line>" to be reviewed and added
#     to go-modfloor.sum (see scripts/go-modfloor-discover.sh).
# Needs network (GOPROXY) unless GOMODCACHE already holds the modules.
set -euo pipefail

GO="${1:?go binary}" SRC="${2:?source dir}" FLOORS="${3:?floors mk}" SUMS="${4:?sums file}" MODFILE="${5:-}"
[[ -x "$GO" ]] || { echo "go-modbump: FATAL: $GO is not executable" >&2; exit 1; }
[[ -f "$FLOORS" && -f "$SUMS" ]] || { echo "go-modbump: FATAL: floors/sums file missing" >&2; exit 1; }
cd "$SRC"

mapfile -t FL < <(sed -n -E 's/^GA_GO_MODFLOOR[[:space:]]*\+?=[[:space:]]*([^[:space:]@]+@v[0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$/\1/p' "$FLOORS")
(( ${#FL[@]} > 0 )) || { echo "go-modbump: FATAL: no GA_GO_MODFLOOR lines in $FLOORS" >&2; exit 1; }

export GOTOOLCHAIN=local GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}" GOFLAGS="-mod=mod -modcacherw${MODFILE:+ -modfile=$MODFILE}"
# Verification comes from the pinned go.sum, never from the environment (see header).
unset GONOSUMDB GONOSUMCHECK GOINSECURE GOPRIVATE GONOPROXY GOVCS
export GOENV=off
if [[ "${GA_GO_MODBUMP_DISCOVER:-}" == 1 ]]; then export GOSUMDB="${GA_GO_MODBUMP_SUMDB:-sum.golang.org}"; else export GOSUMDB=off; fi
SUMFILE="go.sum"
[[ -n "$MODFILE" ]] && SUMFILE="${MODFILE%.mod}.sum"
MODF="${MODFILE:-go.mod}"
[[ -f "$MODF" ]] || { echo "go-modbump: FATAL: $SRC/$MODF not found" >&2; exit 1; }

# 1. pin the floor releases
touch "$SUMFILE"
KNOWN="$(mktemp)"; trap 'rm -f "$KNOWN"' EXIT
cat "$SUMFILE" "$SUMS" > "$KNOWN"
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

# 3b. every go.sum line must be upstream's own or pinned in SUMS
bad=0
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  grep -qxF -- "$line" "$KNOWN" && continue
  if [[ "${GA_GO_MODBUMP_DISCOVER:-}" == 1 ]]; then echo "go-modbump: PIN $line"; continue; fi
  m="${line%% h1:*}"
  echo "go-modbump: FATAL: unpinned go.sum entry for ${m% *}@${m#* } ($line) - the floor set needs this module but $SUMS does not pin it; regenerate with scripts/go-modfloor-discover.sh and review" >&2
  bad=1
done < "$SUMFILE"

# 4. fail closed if anything is still below its floor
for f in "${FL[@]}"; do
  mod="${f%@*}" fv="${f#*@}" cv="$(cur "$mod")"
  [[ -z "$cv" ]] && continue
  if lt "$cv" "$fv"; then echo "go-modbump: FATAL: $mod is $cv, floor $fv" >&2; bad=1; fi
done
exit "$bad"
