#!/usr/bin/env bash
# go-modfloor-discover.sh GO_BIN SRCDIR [MODFILE]
#
# Maintenance helper for buildroot-external/go-modfloor.sum. Runs scripts/go-modbump.sh
# in discover mode on a COPY of SRCDIR (an extracted package tree) and prints the
# go.sum lines the floor bump needs that go-modfloor.sum does not pin yet. The lines
# come from `go` verified against the checksum database (sum.golang.org), never from
# the build hook (which runs GOSUMDB=off). Review them, add the ones you accept to
# go-modfloor.sum, repeat for every Go package in go-modfloor.mk.
# GOFLAGS/GOPROXY/GOMODCACHE are the caller's; the go.env of an upstream Go is assumed.
set -euo pipefail
GO="${1:?go binary}" SRC="${2:?package source dir}" MODFILE="${3:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cp -a "$SRC/." "$W/"
GA_GO_MODBUMP_DISCOVER=1 "$HERE/go-modbump.sh" "$GO" "$W" "$HERE/../buildroot-external/go-modfloor.mk" "$HERE/../buildroot-external/go-modfloor.sum" ${MODFILE:+"$MODFILE"} \
  | sed -n 's/^go-modbump: PIN //p' | sort -u
