#!/bin/sh
# http_config_verdict.sh — judge the HTTP config Core 2026.8+ is RUNNING.
#
# Usage: http_config_verdict.sh <check> <http_config.json> [services_ip]
#   <check>  one of: readable | xff | loopback | services | settled
#   <http_config.json>  the output of http_config_query.py (websocket result)
# Prints one line of evidence; exit 0 = pass, 1 = fail.
#
# Pure (sh + jq), so CI drives it over fixtures (selftest.sh next to this file)
# and the device runs the same file. The expectations are constants of the
# design, never read from the config under test:
#   * use_x_forwarded_for is true
#   * trusted_proxies holds the loopback and the GA services address — Core
#     stores each as a network (`127.0.0.1/32`), so a bare address and its
#     /32 are the same entry
#   * nothing is waiting: pending is null and the server runs `stable`
#
# WHY THE RUNNING CONFIG AND NOT THE FILE. Core 2026.8 imports a YAML `http:`
# block once, at the first start, and ignores it from then on. On a fresh flash
# that first start happens before ga_manager writes ga_packages/ga_http.yaml,
# so the file can be perfect while Core trusts no proxy at all. CFG-32..34 read
# that file until 2026-09-28 — green while every request through the services
# host was refused.

check="$1"; f="$2"; svc="${3:-}"

command -v jq >/dev/null 2>&1 || { echo "jq not available"; exit 1; }
[ -s "$f" ] || { echo "no answer from http/config (empty file)"; exit 1; }

err=$(jq -r '.error | strings' "$f" 2>/dev/null)
[ -z "$err" ] || { echo "http/config not asked: $err"; exit 1; }
if [ "$(jq -r '.success // false' "$f" 2>/dev/null)" != "true" ]; then
  echo "http/config refused: $(jq -c '.error // .' "$f" 2>/dev/null | cut -c1-200)"; exit 1
fi

# The slot the server is actually running (config.py ActiveConfigType): the
# pending one while under trial, stable normally, the built-in default after a
# fallback — which trusts no proxy, and must read as such.
running='(.result.active_config_type) as $t | if $t == "pending" then .result.pending elif $t == "stable" then .result.stable else .result.default end'

has_proxy() {  # <address>
  jq -e --arg a "$1" "($running) | (.trusted_proxies // []) | map(tostring) | any(. == \$a or . == (\$a + \"/32\"))" "$f" >/dev/null 2>&1
}
proxies() { jq -c "($running) | .trusted_proxies // []" "$f" 2>/dev/null; }

case "$check" in
  readable)
    t=$(jq -r '.result.active_config_type // empty' "$f")
    [ -n "$t" ] || { echo "result has no active_config_type"; exit 1; }
    echo "http/config answered (active_config_type=$t)"
    ;;
  xff)
    v=$(jq -r "($running) | .use_x_forwarded_for // false" "$f")
    echo "running use_x_forwarded_for=$v"
    [ "$v" = "true" ]
    ;;
  loopback)
    echo "running trusted_proxies=$(proxies)"
    has_proxy 127.0.0.1
    ;;
  services)
    [ -n "$svc" ] || { echo "no services address given"; exit 1; }
    echo "running trusted_proxies=$(proxies), want $svc"
    has_proxy "$svc"
    ;;
  settled)
    t=$(jq -r '.result.active_config_type // "?"' "$f")
    p=$(jq -c '.result.pending' "$f")
    echo "active_config_type=$t pending=$(printf '%s' "$p" | cut -c1-120)"
    [ "$t" = "stable" ] && [ "$p" = "null" ]
    ;;
  *)
    echo "unknown check '$check'"; exit 1 ;;
esac
