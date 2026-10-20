#!/bin/bash
# telegraf-version-guard.sh -- fail if the telegraf binary was not built with its
# version stamped in (Odoo #1219: it reported "unknown").
#
#   telegraf-version-guard.sh BINARY EXPECTED_VERSION
#
# telegraf takes its version from the Go linker variable
# github.com/influxdata/telegraf/internal.Version. Without `-X ...Version=<v>`
# in the ldflags it stays "unknown", and inventory / CVE matching by version
# sees nothing. Go records the build's ldflags in the binary's build info
# (readable with strings(1), also after -s -w), so the stamp can be read from
# the shipped binary without running it (the target is armv7/aarch64; the build
# host usually cannot execute it).
#
# Compares two independent sources: the version the .mk DECLARES (the caller
# passes it) and the version the BINARY carries. Neither is derived from the other.
#
# Exit 0 = stamped with exactly EXPECTED_VERSION, 1 = not, 2 = could not check.
set -u
BIN=${1:?binary}; WANT=${2:?expected version}
[ -f "$BIN" ] || { echo "telegraf-version-guard: ERROR: no binary at $BIN" >&2; exit 2; }
command -v strings >/dev/null || { echo "telegraf-version-guard: ERROR: strings(1) not found" >&2; exit 2; }
case "$WANT" in ''|*[!0-9A-Za-z._+-]*) echo "telegraf-version-guard: ERROR: bad expected version '$WANT'" >&2; exit 2 ;; esac

stamps=$(strings -a "$BIN" | grep -o 'telegraf/internal\.Version=[^[:space:]"]*' | sort -u)
if [ -z "$stamps" ]; then
    echo "telegraf-version-guard: FAIL: $BIN carries no internal.Version ldflag - it will report 'unknown'" >&2
    exit 1
fi
if [ "$stamps" != "telegraf/internal.Version=$WANT" ]; then
    echo "telegraf-version-guard: FAIL: binary stamps [$(echo "$stamps" | tr '\n' ' ')] but the package pins $WANT" >&2
    exit 1
fi
echo "telegraf-version-guard: ok: binary stamped with internal.Version=$WANT"
