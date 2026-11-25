#!/bin/sh
# FW-41 / FW-43: the device answers over the mesh, asked the way its users ask it.
# Runs on a MESH PEER, not on the device. Read-only: one ssh banner and three GET requests.
#
#   mesh_probe.sh <device mesh address> [<device id>]
#   GA_FM_URL, GA_FM_TOKEN_FILE   fleet manager and a read token file, for FW-43
#
# Exit: 0 all passed, 1 a check failed, 2 something was not run (nothing proven by it).
set -u
IP="${1:-}"; DEV="${2:-}"
[ -n "$IP" ] || { echo "usage: $0 <device mesh address> [<device id>]" >&2; exit 2; }
SSH_P="${GA_P_SSH:-22222}"; GM_P="${GA_P_GM:-8099}"; HA_PS="${GA_P_HA:-80 8123}"
command -v curl >/dev/null && command -v python3 >/dev/null || { echo "NOT RUN: curl/python3 missing"; exit 2; }
P=0; F=0; S=0
res() { if [ "$1" = 0 ]; then P=$((P + 1)); echo "  PASS  $2"; else F=$((F + 1)); echo "  FAIL  $2"; fi; }
code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$@"; }

# An open port is not an answer: each check reads what the service itself says.
python3 -I -c 'import socket,sys
s=socket.create_connection((sys.argv[1],int(sys.argv[2])),8); s.settimeout(8); sys.exit(0 if s.recv(4)==b"SSH-" else 1)' "$IP" "$SSH_P" 2>/dev/null
res $? "FW-41a ssh answers with its banner on :$SSH_P"
c=$(code "http://$IP:$GM_P/livez"); [ "$c" = 200 ]; res $? "FW-41b ga_manager /livez on :$GM_P (HTTP $c)"
hit=; for p in $HA_PS; do c=$(code "http://$IP:$p/auth/providers"); [ "$c" = 200 ] && { hit=$p; break; }; done
[ -n "$hit" ]; res $? "FW-41c Home Assistant /auth/providers (port ${hit:-none of $HA_PS})"

if [ -n "$DEV" ] && [ -n "${GA_FM_URL:-}" ] && [ -r "${GA_FM_TOKEN_FILE:-}" ]; then
  fm() { printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '\r\n' < "$GA_FM_TOKEN_FILE")" | curl -s -K - -o /dev/null -m 40 -w '%{http_code}' "$GA_FM_URL/api/devices/$1/info"; }
  # /info is a live call fleet manager -> device :8099, not a cached row. The control id keeps
  # "answers 200 to anything" from passing.
  c=$(fm "$DEV"); k=$(fm "NO-SUCH-DEVICE-00000000")
  [ "$c" = 200 ] && [ "$k" != 200 ]; res $? "FW-43 fleet manager reaches the device live (HTTP $c, control $k)"
else
  S=$((S + 1)); echo "  NOT RUN  FW-43: needs <device id>, GA_FM_URL and GA_FM_TOKEN_FILE"
fi
echo "--- $P passed, $F failed, $S not run"
[ "$F" = 0 ] || exit 1
[ "$S" = 0 ] || exit 2
