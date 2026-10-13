#!/usr/bin/env bash
# =============================================================================
# mirror_utc.sh — the fleet-manager mirror posts validity in UTC
# =============================================================================
# `ssh-keygen -L` prints the validity window in local time without an offset.
# The mirrored ledger row must carry the UTC instant. Drives the LIVE
# ga-sign-ssh-cert.sh with a fixture `ssh-keygen -L` output (09:00 -> 17:00 in
# CEST, i.e. 07:00Z -> 15:00Z) and a recording curl; asserts the POST body.
# Also a winter (CET) fixture, so a hard-coded +2h would not pass.
# Offline, ~1 second.
# -----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SIGN="$ROOT/scripts/ops/ga-sign-ssh-cert.sh"
RED=$'\033[0;31m'; GRN=$'\033[0;32m'; NC=$'\033[0m'
fails=0; ran=0
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$NC" "$*"; fails=$((fails + 1)); }
ok()  { printf '  %sok%s    %s\n' "$GRN" "$NC" "$*"; }
[[ -r "$SIGN" ]] || { echo "FATAL: $SIGN missing"; exit 1; }
REAL_KEYGEN="$(command -v ssh-keygen)" || { echo "FATAL: ssh-keygen required"; exit 1; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
"$REAL_KEYGEN" -q -t ed25519 -N '' -C ca -f "$W/ca"
"$REAL_KEYGEN" -q -t ed25519 -N '' -C user -f "$W/user"

# ssh-keygen: only `-L` is faked (fixture from $FIX_L); signing is the real one.
cat > "$W/bin/ssh-keygen" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ "\$a" == "-L" ]]; then cat "\$FIX_L"; exit 0; fi
done
exec "$REAL_KEYGEN" "\$@"
EOF
cat > "$W/bin/curl" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do [[ "$1" == "-d" ]] && printf '%s\n' "$2" >> "$CURL_LOG"; shift; done
exit 0
EOF
chmod +x "$W/bin/ssh-keygen" "$W/bin/curl"

fixture() {  # <from> <to>
  cat > "$FIX_L" <<EOF
        Type: ssh-ed25519-cert-v01@openssh.com user certificate
        Signing CA: ED25519 SHA256:FIXTUREFIXTUREFIXTUREFIXTUREFIXTUREFIXTUREFIXT (using ssh-ed25519)
        Key ID: "t@ga"
        Serial: 1
        Valid: from $1 to $2
        Principals:
                KIB-SON-00000001
EOF
}
run() {  # <TZ> <from> <to> <want_from> <want_to> <desc>
  ran=$((ran+1)); export FIX_L="$W/L.txt" CURL_LOG="$W/curl.log"; : > "$CURL_LOG"; fixture "$2" "$3"
  cp "$W/user.pub" "$W/k.pub"
  local out rc=0
  out="$(TZ="$1" PATH="$W/bin:$PATH" GA_SSH_CA_KEY="$W/ca" GA_SSH_ALLOW_FILE_CA=1 \
    GA_CERT_LEDGER="$W/ledger" GA_CERT_SERIAL_STATE="$W/serial" \
    GA_FLEET_URL=http://fm.invalid GA_FLEET_TOKEN=dummy \
    bash "$SIGN" --anchor ANCHOR1 KIB-SON-00000001 "$W/k.pub" 2>&1)" || rc=$?
  if (( rc != 0 )); then bad "$6 — sign script exited $rc: $(tail -1 <<<"$out")"; return; fi
  local body; body="$(head -1 "$CURL_LOG")"
  if [[ "$body" == *"\"valid_from\":\"$4\""* && "$body" == *"\"valid_to\":\"$5\""* ]]; then ok "$6"
  else bad "$6 — want $4 .. $5, posted: $body"; fi
}

run Europe/Berlin 2026-10-13T09:00:00 2026-10-13T17:00:00 2026-10-13T07:00:00Z 2026-10-13T15:00:00Z "CEST 09:00-17:00 -> 07:00Z-15:00Z"
run Europe/Berlin 2026-01-13T09:00:00 2026-01-13T17:00:00 2026-01-13T08:00:00Z 2026-01-13T16:00:00Z "CET (winter) 09:00-17:00 -> 08:00Z-16:00Z"
run UTC           2026-10-13T09:00:00 2026-10-13T17:00:00 2026-10-13T09:00:00Z 2026-10-13T17:00:00Z "UTC signer unchanged"

(( ran == 3 )) || { echo "FATAL: ran $ran cases, expected 3"; exit 1; }
(( fails == 0 )) && { echo "mirror_utc: $ran/$ran ok"; exit 0; }
echo "mirror_utc: $fails of $ran FAILED"; exit 1
