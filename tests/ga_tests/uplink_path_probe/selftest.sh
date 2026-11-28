#!/bin/sh
# ga-uplink-path-probe (Odoo #2201 D2): the LIVE helper against stub curl/ip.
# Only the transport is stubbed: what each interface answers per attempt.
# Verdicts must be clean / unclean (loss, portal body, slow) / dead / no_route,
# the endpoint comes from the REAL 50-ga.conf, and a missing endpoint fails closed.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
P="$ROOT/buildroot-external/rootfs-overlay/usr/libexec/ga-uplink-path-probe"
CONF="$ROOT/buildroot-external/rootfs-overlay/etc/NetworkManager/conf.d/50-ga.conf"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1 ($2)"; fail=$((fail+1)); }
[ -x "$P" ] || { echo "FATAL: $P missing"; exit 2; }
grep -q '^uri=https://' "$CONF" || { echo "FATAL: $CONF has no [connectivity] uri (the helper reads it)"; exit 2; }
# curl stub: $W/plan.<iface> holds one line per attempt: "<code> <seconds> <body>"
cat > "$W/curl" <<'STUB'
#!/bin/sh
i=""; u=""; while [ $# -gt 0 ]; do case "$1" in --interface) i="$2"; shift ;; https://*|http://*) u="$1" ;; esac; shift; done
echo "$i $u" >> "$W/curl.log"
n=$(( $(cat "$W/n.$i" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$W/n.$i"
line=$(sed -n "${n}p" "$W/plan.$i" 2>/dev/null)
[ -n "$line" ] || { exit 28; }
code=${line%% *}; rest=${line#* }; t=${rest%% *}; body=${rest#* }
[ "$code" = 000 ] && { printf '\n000 %s' "$t"; exit 28; }
printf '%s\n%s %s' "$body" "$code" "$t"
STUB
cat > "$W/ip" <<'STUB'
#!/bin/sh
# ip -4 route show default dev IFACE
for a; do d="$a"; done
grep -qx "$d" "$W/routes" && echo "default via 192.0.2.1 dev $d proto dhcp metric 100"
exit 0
STUB
sed -i "s|\$W|$W|g" "$W/curl" "$W/ip"; chmod +x "$W/curl" "$W/ip"
B='NetworkManager is online'
run() { rm -f "$W"/n.* "$W/curl.log"; GA_CURL="$W/curl" GA_IP="$W/ip" GA_UPLINK_NM_CONF="${C:-$CONF}" sh "$P" "$@" 2>"$W/err"; }
v() { printf '%s\n' "$1" | grep "\"iface\":\"$2\"" | sed -n 's/.*"verdict":"\([a-z_]*\)".*/\1/p'; }
printf 'eth0\nwlan0\n' > "$W/routes"

printf '200 0.120 %s\n200 0.140 %s\n200 0.130 %s\n' "$B" "$B" "$B" > "$W/plan.eth0"
out=$(run eth0); [ "$(v "$out" eth0)" = clean ] && ok "3/3 answered fast -> clean" || no "clean" "$out"
printf '%s' "$out" | grep -q '"ms_median":130' && ok "median of 120/140/130 ms is 130" || no "median" "$out"
grep -q "eth0 https://checkonline.greenautarky.com/online.txt" "$W/curl.log" && ok "probes the endpoint from the REAL 50-ga.conf, bound to the interface" || no "endpoint/bind" "$(cat "$W/curl.log")"

printf '200 0.120 %s\n000 8.0 x\n200 0.130 %s\n' "$B" "$B" > "$W/plan.eth0"
out=$(run eth0); [ "$(v "$out" eth0)" = unclean ] && ok "1 of 3 lost -> unclean" || no "loss" "$out"
printf '200 0.120 <html>portal</html>\n200 0.1 <html>portal</html>\n200 0.1 <html>portal</html>\n' > "$W/plan.eth0"
out=$(run eth0); [ "$(v "$out" eth0)" = unclean ] && printf '%s' "$out" | grep -q 'wrong status/body' && ok "200 with a portal body -> unclean (never clean)" || no "portal" "$out"
printf '302 0.1 x\n302 0.1 x\n302 0.1 x\n' > "$W/plan.eth0"
out=$(run eth0); [ "$(v "$out" eth0)" = unclean ] && ok "redirect (captive portal) -> unclean" || no "redirect" "$out"
printf '200 2.1 %s\n200 1.9 %s\n200 2.4 %s\n' "$B" "$B" "$B" > "$W/plan.eth0"
out=$(run eth0); [ "$(v "$out" eth0)" = unclean ] && printf '%s' "$out" | grep -q '> 1500 ms' && ok "median 2100 ms > 1500 -> unclean" || no "slow" "$out"
printf '200 1.5 %s\n200 1.5 %s\n200 1.5 %s\n' "$B" "$B" "$B" > "$W/plan.eth0"
out=$(run eth0); [ "$(v "$out" eth0)" = clean ] && ok "median exactly 1500 ms -> clean (boundary)" || no "boundary" "$out"
: > "$W/plan.eth0"
out=$(run eth0); [ "$(v "$out" eth0)" = dead ] && ok "no answer -> dead" || no "dead" "$out"
printf 'eth0\n' > "$W/routes"
out=$(run eth0 wlan0); [ "$(v "$out" wlan0)" = no_route ] && [ "$(printf '%s\n' "$out" | wc -l)" = 2 ] && ok "interface without a default route -> no_route, one line per interface" || no "no_route" "$out"
grep -q '^wlan0 ' "$W/curl.log" 2>/dev/null && no "no_route sends nothing" "wlan0 was probed" || ok "no_route interface is not probed"
printf 'eth0\nwlan0\n' > "$W/routes"
printf '200 0.1 %s\n200 0.1 %s\n200 0.1 %s\n' "$B" "$B" "$B" > "$W/plan.eth0"; : > "$W/plan.wlan0"
out=$(run eth0 wlan0); [ "$(v "$out" eth0)" = clean ] && [ "$(v "$out" wlan0)" = dead ] && ok "two paths judged independently (eth0 clean, wlan0 dead)" || no "independent" "$out"
printf '[main]\nx=1\n' > "$W/bad.conf"
C="$W/bad.conf" run eth0 >/dev/null; rc=$?
[ "$rc" = 2 ] && grep -q 'nothing measured' "$W/err" && ok "no endpoint in the conf -> exit 2, loud (fail closed)" || no "no conf" "rc=$rc"

echo "Results: $pass passed, $fail failed"
[ "$pass" -ge 13 ] || { echo "FAIL: only $pass checks"; exit 2; }
[ "$fail" -eq 0 ]
