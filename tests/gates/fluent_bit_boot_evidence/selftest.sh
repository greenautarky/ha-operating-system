#!/usr/bin/env bash
# fluent_bit_boot_evidence/selftest.sh — no shipped systemd input skips boot-time
# journal lines unless it says why.
#
# WHY
#   A field device logged 12 "UNCLEAN SHUTDOWN DETECTED" lines (ga-boot-check)
#   and none reached Loki in 30 days: the tier-1 systemd input had
#   `Read_From_Tail true`, so everything journald held before fluent-bit started
#   (early boot) was skipped. A line written before the shipper starts is the
#   most valuable one after a crash.
#
# RULE (per [INPUT] with Name systemd, in every shipped fluent-bit config)
#   1. Read_From_Tail true/on/yes/1 needs a `# tail-ok: <reason>` comment line
#      directly above its [INPUT] header.
#   2. Without a tail-ok reason it needs a DB cursor (no DB + from-start =
#      every restart re-sends).
#   (tail inputs are out of scope: in_tail has its own offset DB semantics.)
#
# Live configs: buildroot-*/rootfs-overlay/etc/fluent-bit/*.conf and
# buildroot-external/package/fluent-bit-config/*.conf. The tier-0 component
# config (external repo) is not covered here; see fluent_bit_cursor_sync.
# The SAME function runs on fixtures and on the live files. Fail closed on zero
# systemd inputs seen. Exit 0 green, 1 verdict failed, 2 could not check.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HERE="$ROOT/tests/gates/fluent_bit_boot_evidence"
die2() { echo "ERROR (could not check): $*" >&2; exit 2; }

# offenders <file> — one line per violating input; "#N <n>" = systemd inputs seen
offenders() {
  awk -v f="$1" '
    function flush() {
      if (sect == "[INPUT]" && name == "systemd") {
        n++
        t = tolower(tail)
        if ((t == "true" || t == "on" || t == "yes" || t == "1") && !ok)
          print f ": " (tag == "" ? "<untagged>" : tag) " Read_From_Tail without a preceding # tail-ok: reason"
        if (!db && !ok) print f ": " (tag == "" ? "<untagged>" : tag) " has no DB cursor"
      }
      name = ""; db = 0; tail = ""; tag = ""
    }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { if ($0 ~ /^[[:space:]]*#[[:space:]]*tail-ok:[[:space:]]*[^[:space:]]/) pend = 1; next }
    /^[[:space:]]*\[/ { flush(); sect = toupper($1); ok = pend; pend = 0; next }
    { pend = 0; k = tolower($1)
      if (k == "name") name = tolower($2)
      else if (k == "db") db = 1
      else if (k == "read_from_tail") tail = $2
      else if (k == "tag") tag = $2 }
    END { flush(); print "#N " n + 0 }
  ' "$1"
}
pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "  ok    $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }

echo "fixtures:"
nf=0 np=0
for f in "$HERE"/must-fail/*.conf; do [ -f "$f" ] || continue; nf=$((nf + 1))
  if offenders "$f" | grep -qv '^#N'; then ok "must-fail $(basename "$f") flagged"; else bad "must-fail $(basename "$f") NOT flagged"; fi; done
for f in "$HERE"/must-pass/*.conf; do [ -f "$f" ] || continue; np=$((np + 1))
  if offenders "$f" | grep -qv '^#N'; then bad "must-pass $(basename "$f") flagged"; else ok "must-pass $(basename "$f") clean"; fi; done
[ "$nf" -ge 1 ] && [ "$np" -ge 1 ] || die2 "fixture dirs empty (must-fail=$nf must-pass=$np)"

LIVE_ROOT="${FB_BOOT_EVIDENCE_ROOT:-$ROOT}"   # test hook: point the live scan at another tree (red proof)
mapfile -t live < <(find "$LIVE_ROOT"/buildroot-*/rootfs-overlay/etc/fluent-bit "$LIVE_ROOT/buildroot-external/package/fluent-bit-config" -name '*.conf' -type f 2>/dev/null | sort)
[ "${#live[@]}" -ge 1 ] || die2 "no fluent-bit configs found in the tree"
echo "live:"
total=0
for f in "${live[@]}"; do
  out="$(offenders "$f")"; n="$(printf '%s\n' "$out" | sed -n 's/^#N //p')"; total=$((total + n))
  lines="$(printf '%s\n' "$out" | grep -v '^#N' || true)"
  if [ -n "$lines" ]; then while IFS= read -r l; do bad "${l/#$f/${f#"$LIVE_ROOT"/}}"; done <<< "$lines"
  else ok "${f#"$LIVE_ROOT"/} ($n systemd inputs)"; fi
done
[ "$total" -ge 1 ] || die2 "live scan saw no systemd input at all — parser or layout changed"
echo "pass=$pass fail=$fail (live systemd inputs inspected: $total)"
[ "$fail" -eq 0 ] && { echo "PASS: no shipped systemd input skips boot-time lines without a reason"; exit 0; }
exit 1
