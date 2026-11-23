#!/bin/sh
# lan_scan_check.sh <board> <gnmap-file> — judge one `nmap -sT -p- -oG -` result against the
# PINNED list lan_open_ports.<board>. Exit 0 = matches, 1 = violation, 2 = unusable input.
#   LSC-01  the open TCP set equals the pinned set exactly (an extra open port fails)
#   LSC-02  the remaining ports are FILTERED (default deny), not answered
#   LSC-03  the scan covered all 65535 ports (a partial scan proves nothing)
set -u
D="$(cd "$(dirname "$0")" && pwd)"; PIN="$D/lan_open_ports.$1"; G="$2"
[ -r "$PIN" ] || { echo "UNUSABLE: no pinned list for board '$1'"; exit 2; }
L=$(grep -E '^Host: .*Ports: ' "$G" 2>/dev/null | head -1)
[ -n "$L" ] || { echo "UNUSABLE: no 'Host: … Ports:' line (host down or empty scan) — not a pass"; exit 2; }
want=$(grep -vE '^[[:space:]]*(#|$)' "$PIN" | sort -n | tr '\n' ' ')
P=$(echo "$L" | sed 's/^.*Ports: //; s/[[:space:]]*Ignored State:.*$//')   # only the port list
open=$(echo "$P" | tr ',' '\n' | sed -n 's#^[[:space:]]*\([0-9][0-9]*\)/open/tcp.*#\1#p' | sort -n | tr '\n' ' ')
listed=$(echo "$P" | tr ',' '\n' | grep -cE '[0-9]+/(open|closed|filtered)/tcp')
ign=$(echo "$L" | sed -n 's/.*Ignored State: \([a-z|]*\) (\([0-9]*\)).*/\1 \2/p')
rc=0
if [ "$open" = "$want" ]; then echo "PASS LSC-01 open TCP = pinned (${want% })"; else echo "FAIL LSC-01 open TCP '${open% }', pinned '${want% }'"; rc=1; fi
set -- $ign
if [ "${1:-}" = filtered ]; then echo "PASS LSC-02 the other ${2} ports are filtered (default deny)"; else echo "FAIL LSC-02 ignored state '${1:-none}' — not default deny"; rc=1; fi
total=$(( ${2:-0} + listed ))
if [ "$total" -eq 65535 ]; then echo "PASS LSC-03 all 65535 TCP ports covered"; else echo "FAIL LSC-03 scan covered $total of 65535 ports"; rc=1; fi
exit $rc
