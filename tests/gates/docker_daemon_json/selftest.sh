#!/usr/bin/env bash
# docker_daemon_json/selftest.sh -- the daemon.json the image ships (upstream HAOS
# + GA patches-haos 0138) carries max-download-attempts 25, keeps every upstream
# key, and is accepted by the dockerd version the image runs.
#
# WHY: a misspelled or malformed daemon.json keeps dockerd from starting at all
# (no Supervisor, no Core), and the same option given BOTH in the file and as a
# dockerd flag does so too. Every expectation below is pinned, none is read from
# the file under test.
#
# must-pass / must-fail fixtures and the live file run through the same check.
# Exit 0 = green, 1 = a verdict failed, 2 = could not check (never green).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HERE="$ROOT/tests/gates/docker_daemon_json"
DIND="${DOCKER_DIND_IMAGE:-docker:29.8.2-dind}"
WANT_ENGINE=29.8.2
P=buildroot-external/rootfs-overlay/etc/docker/daemon.json
die2() { echo "ERROR (could not check): $*" >&2; exit 2; }
command -v docker >/dev/null || die2 "docker not on PATH"
command -v jq >/dev/null || die2 "jq not on PATH"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT; chmod 755 "$W"
docker run --rm --network none --entrypoint dockerd "$DIND" --version > "$W/ver" 2>&1 || die2 "$DIND: $(tail -1 "$W/ver")"
grep -q "version $WANT_ENGINE," "$W/ver" || die2 "$DIND is not docker $WANT_ENGINE: $(cat "$W/ver")"
grep -q "MIN_DOCKER_ENGINE=$WANT_ENGINE" "$ROOT/scripts/check-container-floor.sh" \
  || die2 "the image's docker-engine moved off $WANT_ENGINE -- update WANT_ENGINE/DIND and re-read the key's handling"

check() {  # check FILE -> "" or the reason
  jq -e . "$1" >/dev/null 2>&1 || { echo "not-json"; return; }
  local v; v="$(jq -c '."max-download-attempts"' "$1")"
  [ "$v" = 25 ] || { echo "attempts=$v"; return; }
  [ "$(jq -cS 'del(."max-download-attempts")' "$1")" = \
    '{"bip":"172.30.232.1/23","data-root":"/mnt/data/docker","ipv6":true,"log-driver":"journald","log-opts":{"tag":"{{.Name}}"}}' ] \
    || { echo "other-keys-changed"; return; }
  cp "$1" "$W/d.json"; chmod 644 "$W/d.json"
  docker run --rm --network none -v "$W/d.json:/d.json:ro" --entrypoint dockerd "$DIND" \
    --validate --config-file /d.json > "$W/val" 2>&1 || { echo "dockerd-refuses"; return; }
}
validate_refuses() {  # dockerd itself must refuse FILE [extra flags]
  local f="$1"; shift; cp "$f" "$W/d.json"; chmod 644 "$W/d.json"
  ! docker run --rm --network none -v "$W/d.json:/d.json:ro" --entrypoint dockerd "$DIND" \
    --validate --config-file /d.json "$@" > "$W/val" 2>&1
}
rc=0; n=0
ok()  { n=$((n + 1)); echo "  ok    $1"; }
bad() { n=$((n + 1)); rc=1; echo "  FAIL  $1"; }

np=0; for f in "$HERE"/must-pass/*.json; do [ -f "$f" ] || continue; np=$((np + 1))
  r="$(check "$f")"; [ -z "$r" ] && ok "must-pass/${f##*/}" || bad "must-pass/${f##*/}: $r"; done
nf=0; for f in "$HERE"/must-fail/*.json; do [ -f "$f" ] || continue; nf=$((nf + 1))
  b="${f##*/}"; want="$(cat "${f%.json}.want")"; r="$(check "$f")"
  [ "$r" = "$want" ] && ok "must-fail/$b: $r" || bad "must-fail/$b: got '${r:-passed}', want '$want'"; done
[ "$np" -ge 1 ] && [ "$nf" -ge 4 ] || die2 "fixtures missing (must-pass=$np must-fail=$nf)"

# dockerd's own refusals, so "dockerd-refuses" above is a real verdict
validate_refuses "$HERE/must-fail/typo.json" && grep -q "don't match any configuration option" "$W/val" \
  && ok "dockerd refuses a misspelled key" || bad "dockerd accepted a misspelled key"
validate_refuses "$HERE/must-pass/ga.json" --max-download-attempts 9 && grep -q "specified both as a flag and in the configuration file" "$W/val" \
  && ok "dockerd refuses the key as file + flag" || bad "file + flag: $(tail -1 "$W/val")"

# live: the file as the build sees it, for BOTH boards (one shared overlay)
[ -f "$ROOT/haos/$P" ] || die2 "haos/ is not checked out"
"$ROOT/scripts/apply-haos-patches.sh" --cat "$P" > "$W/live.json" 2> "$W/cat.err" || die2 "$(tail -1 "$W/cat.err")"
r="$(check "$W/live.json")"; [ -z "$r" ] && ok "live daemon.json" || bad "live daemon.json: $r"
# a GA layer copy would replace the patched file on its board without a trace
dup="$(git -C "$ROOT" ls-files | grep -E '(^|/)etc/docker/daemon\.json$' || true)"
[ -z "$dup" ] && ok "no second daemon.json in the GA layers" || bad "second daemon.json: $dup"
# dockerd's command line (unit + docker-prepare) must not carry the option too
for u in buildroot-external/rootfs-overlay/usr/libexec/docker-prepare \
         buildroot-external/rootfs-overlay/usr/lib/systemd/system/docker.service.d/haos.conf; do
  "$ROOT/scripts/apply-haos-patches.sh" --cat "$u" > "$W/u" 2>/dev/null && [ -s "$W/u" ] || die2 "cannot read $u"
  grep -q 'max-download-attempts' "$W/u" && bad "$u passes the option as a flag" || ok "${u##*/}: option not passed as a flag"
done
[ "$rc" = 0 ] && echo "PASS: $n checks"
exit "$rc"
