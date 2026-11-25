#!/bin/sh
# Host-side selftest of PING-03 (no-consent branch: gateway from `ip route`): the LIVE suite
# against stub ip/ping. Known-good PASS; no default route and an unreachable gateway FAIL.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/devsuite_selftest.sh"
ds_init
cat > "$W/bin/ip" <<'STUB'
#!/bin/sh
[ "$1" = route ] && [ -f "$FAKE/route" ] && cat "$FAKE/route"
exit 0
STUB
cat > "$W/bin/ping" <<'STUB'
#!/bin/sh
# 127.0.0.1 always answers (the suite's "is ping usable" probe); other hosts only if listed in $FAKE/up
for a; do h=$a; done
[ "$h" = 127.0.0.1 ] && exit 0
grep -qx "$h" "$FAKE/up" 2>/dev/null
STUB
chmod +x "$W/bin/"*
F="$W/f"; mkdir -p "$F"
run() { ds_run ping FAKE="$F"; }

printf 'default via gw-a dev eth0 proto dhcp metric 100\nlan-a dev eth0\n' > "$F/route"; echo gw-a > "$F/up"; run
ds_expect PING-03 PASS "default route found, gateway answers"
grep -q 'from ip route: gw-a' "$W/out" && { echo "  ok    the gateway is shown in the title"; DS_PASS=$((DS_PASS+1)); } || { echo "  FAIL  title lacks the gateway"; DS_FAIL=$((DS_FAIL+1)); }
: > "$F/up"; run;                  ds_expect PING-03 FAIL "gateway does not answer"
: > "$F/route"; echo gw-a > "$F/up"; run; ds_expect PING-03 FAIL "no default route"
ds_done
