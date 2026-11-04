#!/bin/bash
# Host/CI self-test of ga-telegraf-buffer-check against a REAL telegraf.
#
# Fixtures are generated at run time by the real telegraf (a WAL written by an
# output that cannot deliver), then corrupted the way a hard reset does: the
# newest segment is truncated in the middle of a record. No hand-made WAL, no
# stub of telegraf: the question "does telegraf panic on this buffer" is
# answered by telegraf itself, before and after the guard.
#
#   TELEGRAF_BIN  real telegraf binary for the HOST arch (required; CI downloads
#                 the pinned release, see the lint workflow). Missing => FAIL.
#   GUARD         the guard under test (default: the live script). Set it to
#                 /bin/true to reproduce the pre-fix state (red proof).
#
# MUST-FLAG (guard has to quarantine): corrupt WAL; repeated corruption (bounded).
# MUST-NOT-FLAG (guard has to leave alone): healthy WAL; broken config with a
# healthy buffer; empty/absent buffer; anything outside the telegraf dir.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="${GUARD:-$HERE/../../../buildroot-external/package/telegraf/ga-telegraf-buffer-check}"
BIN="${TELEGRAF_BIN:-}"
CASES=0; FAILS=0

fail() { echo "  FAIL  $1"; FAILS=$((FAILS + 1)); }
ok()   { echo "  PASS  $1"; }
check() { CASES=$((CASES + 1)); if eval "$2" >/dev/null 2>&1; then ok "$1"; else fail "$1"; fi; }

if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "FAIL: TELEGRAF_BIN not set or not executable ('$BIN') -- refusing to skip"
    exit 1
fi
[ -f "$GUARD" ] || [ -x "$GUARD" ] || { echo "FAIL: guard '$GUARD' not found"; exit 1; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

SHIPPED="$HERE/../../../buildroot-external/package/telegraf/telegraf.conf"
# The SHIPPED config (its hash decides the WAL dir), only the buffer dir and the
# unreachable influx URL rewritten; env as ga-telegraf-env provides it.
export INFLUX_USER=u INFLUX_PASSWORD=p DEVICE_LABEL=x DEVICE_UUID=y GA_ENV=staging \
       GATEWAY_IP=1.1.1.1 GA_BUILD_TIMESTAMP=z GA_TELEMETRY_ENV=staging
write_conf() { # <file> <bufdir>
    # agent interval/flush shortened (first two occurrences = [agent]) so segments exist within seconds
    sed -E "s|^([[:space:]]*buffer_directory[[:space:]]*=).*|\1 \"$2\"|; s|http://influx.greenautarky.com:8086|http://127.0.0.1:9|; 0,/^[[:space:]]*interval = /s|^([[:space:]]*interval = ).*|\1\"1s\"|; 0,/^[[:space:]]*flush_interval = /s|^([[:space:]]*flush_interval = ).*|\1\"1s\"|" "$SHIPPED" > "$1"
}

# --- template: a REAL agent run writes the WAL (not config check) -------------
TPL="$W/tpl"; mkdir -p "$TPL"
write_conf "$W/tpl.conf" "$TPL"
timeout 12 "$BIN" --config "$W/tpl.conf" >/dev/null 2>&1
seg=$(find "$TPL" -type f | sort | tail -1)
size=0; [ -n "$seg" ] && size=$(wc -c < "$seg")
if [ "$size" -lt 1000 ]; then echo "FAIL: telegraf wrote no WAL segment to the template (size=$size) -- cannot build fixtures"; exit 1; fi
TPL_DIRS=$(ls "$TPL")
[ "$(echo "$TPL_DIRS" | wc -l)" -eq 1 ] || { echo "FAIL: real run left several WAL dirs: $TPL_DIRS"; exit 1; }

# new_dev <name>: a fake /mnt/data/telegraf with a copy of the healthy WAL
new_dev() {
    D="$W/$1/telegraf"; mkdir -p "$D"; cp -r "$TPL" "$D/buffer"
    write_conf "$D/conf" "$D/buffer"
    mkdir -p "$W/$1/other"; echo keep > "$W/$1/other/sentinel"
}
corrupt() { # truncate newest segment mid-record
    s=$(find "$1/buffer" -type f | sort | tail -1)
    truncate -s $((size - 700)) "$s"
}
run_guard() { # <dev-name>  -> output in $OUT
    OUT=$(GA_TELEGRAF_DIR="$W/$1/telegraf" GA_TELEGRAF_CONF="$W/$1/telegraf/conf" GA_TELEGRAF_BIN="$BIN" "$GUARD" 2>&1)
    RC=$?
}
loads() { "$BIN" --config "$1" --test --input-filter mem >/dev/null 2>&1; }
tree_sum() { (cd "$1" && find . -type f | sort | xargs sha256sum | sha256sum); }

echo "== detector opens the SAME WAL dir as the real run"
new_dev d1
check "detector run creates no extra WAL dir and keeps the real one" "loads $W/d1/telegraf/conf && [ \"\$(ls $W/d1/telegraf/buffer)\" = \"$TPL_DIRS\" ]"
check "config check (the rejected detector) WOULD open another dir" "$BIN config check --config $W/d1/telegraf/conf >/dev/null 2>&1; [ \$(ls $W/d1/telegraf/buffer | wc -l) -eq 2 ]"

echo "== MUST-FLAG: corrupt WAL"
new_dev c1; corrupt "$W/c1/telegraf"
check "precondition: telegraf PANICS on the corrupt buffer" "! loads $W/c1/telegraf/conf"
run_guard c1
check "guard exits 0" "[ $RC -eq 0 ]"
check "telegraf loads the config afterwards" "loads $W/c1/telegraf/conf"
check "a buffer.corrupt-* quarantine exists" "ls -d $W/c1/telegraf/buffer.corrupt-*"
check "quarantine holds the corrupt segment" "[ -n \"\$(find $W/c1/telegraf/buffer.corrupt-* -type f)\" ]"
check "new buffer dir exists" "[ -d $W/c1/telegraf/buffer ]"
check "warning line carries the <4> priority prefix" "printf '%s\n' \"\$OUT\" | grep -q '^<4>ga-telegraf-buffer-check: .*CORRUPT'"
check "nothing outside the telegraf dir touched" "[ \"\$(cat $W/c1/other/sentinel)\" = keep ] && [ \"\$(ls $W/c1)\" = \"other
telegraf\" ]"

echo "== MUST-FLAG: repeated corruption stays bounded (keep 2)"
new_dev c2
for _ in 1 2 3 4; do
    rm -rf "$W/c2/telegraf/buffer"; cp -r "$TPL" "$W/c2/telegraf/buffer"; corrupt "$W/c2/telegraf"
    run_guard c2
done
check "4 corruptions leave exactly 2 quarantines" "[ \$(ls -d $W/c2/telegraf/buffer.corrupt-* | wc -l) -eq 2 ]"
check "telegraf still loads" "loads $W/c2/telegraf/conf"

echo "== MUST-NOT-FLAG: healthy WAL"
new_dev h1; before=$(tree_sum "$W/h1/telegraf/buffer")
check "precondition: telegraf loads the healthy buffer" "loads $W/h1/telegraf/conf"
run_guard h1
check "guard exits 0" "[ $RC -eq 0 ]"
check "buffer content byte-identical" "[ \"\$(tree_sum $W/h1/telegraf/buffer)\" = \"$before\" ]"
check "no extra WAL dir created in the healthy buffer" "[ \"\$(ls $W/h1/telegraf/buffer)\" = \"$TPL_DIRS\" ]"
check "no quarantine created" "! ls -d $W/h1/telegraf/buffer.corrupt-*"
check "no warning logged" "! printf '%s\n' \"\$OUT\" | grep -q '^<[0-4]>'"

echo "== MUST-NOT-FLAG: unrelated config error, healthy buffer"
new_dev u1; echo '[[inputs.does_not_exist_ga]]' >> "$W/u1/telegraf/conf"; before=$(tree_sum "$W/u1/telegraf/buffer")
run_guard u1
check "buffer untouched" "[ \"\$(tree_sum $W/u1/telegraf/buffer)\" = \"$before\" ]"
check "no quarantine created" "! ls -d $W/u1/telegraf/buffer.corrupt-*"

echo "== MUST-NOT-FLAG: empty buffer dir"
new_dev e1; rm -rf "$W/e1/telegraf/buffer"; mkdir "$W/e1/telegraf/buffer"
run_guard e1
check "no quarantine created" "! ls -d $W/e1/telegraf/buffer.corrupt-*"

echo
echo "cases=$CASES failed=$FAILS"
[ "$CASES" -gt 0 ] || { echo "FAIL: zero cases ran"; exit 1; }
[ "$FAILS" -eq 0 ]
