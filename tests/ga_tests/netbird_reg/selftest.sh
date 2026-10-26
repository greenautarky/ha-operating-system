#!/bin/sh
# ga-netbird-register — the LIVE script, run for real against a stub netbird
# daemon. No device, no network. Host suite (CI lint.yml host-suites).
#
# The subject is buildroot-external/rootfs-overlay/usr/libexec/ga-netbird-register
# itself, never a copy of its rules. `netbird`, `curl` and `sleep` are stubs:
# the test decides what `netbird status` reports before and after `up`, what
# `up` exits with, and reads back which key `up` was given (by name, never by
# value), what is left on the fake boot partition, the exit status and the
# priority of every line the script logged.
#
# Fixture families (working-method rule 51):
#   MUST-JOIN-AND-RETIRE  boot-partition key + join confirmed -> key file
#                         deleted, exit 0; leftover key on an already joined
#                         device -> deleted without a new `up`.
#   MUST-KEEP             `up` fails; `up` exits 0 but the daemon stays in
#                         NeedsLogin; `up` exits 0 but no NetBird IP; daemon not
#                         answering -> key file KEPT, exit 1 (retry), err line.
#   MUST-BE-LOUD          no usable key anywhere -> err-priority line, exit 78,
#                         and the unit maps 78 to "no restart" (no crash loop).
#   FALLBACK              no boot-partition key -> the baked key is used (the
#                         image still bakes it until a later step).
#   NEVER                 no output ever contains the key value.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "ga-netbird-register (boot-partition key, delete after confirmed join)"

ROOT="$SCRIPT_DIR/../../.."
REG="${GA_NETBIRD_REGISTER_BIN:-$ROOT/buildroot-external/rootfs-overlay/usr/libexec/ga-netbird-register}"
UNIT="$ROOT/buildroot-external/rootfs-overlay/usr/lib/systemd/system/ga-netbird-register.service"
# Pinned, not read from the script: the flasher writes exactly this file.
WANT_BOOT_DEFAULT='/mnt/boot/ga-netbird-setup-key'

run_test "NBR-00" "the register script exists and is executable" "test -x '$REG'"

W="$(mktemp -d "${TMPDIR:-/tmp}/nb_reg.XXXXXX")"
trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
mkdir -p "$W/bin"
BOOT_FAKE="00000000-0000-4000-8000-0000000000b0"    # not a real key
BAKED_FAKE="00000000-0000-4000-8000-0000000000ba"   # not a real key

# netbird stub. $W/state: needslogin | joined | connecting | down
#   status -> output shaped like the real CLI for that state
#   up     -> records which fake key it was given, exits $W/up_rc, and moves
#             the state to $W/after_up (what the daemon really did)
cat > "$W/bin/netbird" <<STUB
#!/bin/sh
for a in "\$@"; do case "\$a" in status|up) cmd="\$a" ;; esac; done
case "\$cmd" in
  status)
    case "\$(cat "$W/state")" in
      needslogin) printf 'Daemon status: NeedsLogin\n\nRun UP command to log in with SSO\n' ;;
      joined)     printf 'Management: Connected\nSignal: Connected\nNetBird IP: 198.51.100.7/24\nPeers count: 0/1 Connected\n' ;;
      connecting) printf 'Management: Connected\nSignal: Disconnected\nNetBird IP: N/A\n' ;;
      down)       echo 'Error: failed to connect to daemon error: context deadline exceeded' >&2; exit 1 ;;
    esac ;;
  up)
    key=""; prev=""
    for a in "\$@"; do [ "\$prev" = "--setup-key" ] && key="\$a"; prev="\$a"; done
    case "\$key" in
      "$BOOT_FAKE")  echo boot  >> "$W/up.log" ;;
      "$BAKED_FAKE") echo baked >> "$W/up.log" ;;
      *)             echo other >> "$W/up.log" ;;
    esac
    cp "$W/after_up" "$W/state"
    exit "\$(cat "$W/up_rc")" ;;
esac
exit 0
STUB
printf '#!/bin/sh\nexit 0\n' > "$W/bin/curl"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/sleep"
chmod +x "$W/bin/netbird" "$W/bin/curl" "$W/bin/sleep"

# nb <state> <up_rc> <after_up> <boot: key|empty|none> <baked: key|none>
# -> sets RC, OUT (all output), UPS (keys `up` got, space separated),
#    BOOT_LEFT (yes|no)
nb() {
  printf '%s\n' "$1" > "$W/state"; printf '%s\n' "$2" > "$W/up_rc"; printf '%s\n' "$3" > "$W/after_up"
  rm -f "$W/up.log"; rm -rf "$W/boot" "$W/rootfs"; mkdir -p "$W/boot" "$W/rootfs"
  case "$4" in
    key)   printf '# written by the flasher\n%s\n' "$BOOT_FAKE" > "$W/boot/ga-netbird-setup-key" ;;
    empty) printf '# nothing here\n\n' > "$W/boot/ga-netbird-setup-key" ;;
  esac
  [ "$5" = key ] && printf '%s\n' "$BAKED_FAKE" > "$W/rootfs/setup-key"
  OUT="$(PATH="$W/bin:$PATH" GA_NETBIRD_BIN="$W/bin/netbird" GA_CURL_BIN="$W/bin/curl" \
    GA_NETBIRD_BOOT_KEY="$W/boot/ga-netbird-setup-key" GA_NETBIRD_BAKED_KEY="$W/rootfs/setup-key" \
    GA_NETBIRD_REACH_TIMEOUT=0 GA_NETBIRD_CONFIRM_TIMEOUT=10 \
    "$REG" 2>&1)"; RC=$?
  UPS=""; [ -f "$W/up.log" ] && UPS="$(tr '\n' ' ' < "$W/up.log" | sed 's/ $//')"
  [ -e "$W/boot/ga-netbird-setup-key" ] && BOOT_LEFT=yes || BOOT_LEFT=no
  printf '%s\n' "$OUT" >> "$W/all.out"
}
has_err() { printf '%s\n' "$OUT" | grep -q '^<3>ga-netbird-register: ERROR:'; }

echo "── MUST-JOIN-AND-RETIRE ──"
nb needslogin 0 joined key none
run_test "NBR-01" "boot key + confirmed join: exit 0" "[ '$RC' = 0 ]"
run_test "NBR-02" "boot key + confirmed join: up got the boot-partition key" "[ '$UPS' = boot ]"
run_test "NBR-03" "boot key + confirmed join: the key file is DELETED" "[ '$BOOT_LEFT' = no ]"

nb joined 0 joined key none
run_test "NBR-04" "already joined + leftover boot key: deleted, exit 0, no new up" \
  "[ '$RC' = 0 ] && [ '$BOOT_LEFT' = no ] && [ -z '$UPS' ]"

nb joined 0 joined none none
E5=$(has_err && echo y)
run_test "NBR-05" "already joined, no key anywhere: exit 0, no error (no loop)" \
  "[ '$RC' = 0 ] && [ -z '$E5' ]"

echo "── MUST-KEEP (the join is measured, not the exit code) ──"
nb needslogin 1 needslogin key none
E6=$(has_err && echo y)
run_test "NBR-06" "up fails: exit 1, key file KEPT, err line" \
  "[ '$RC' = 1 ] && [ '$BOOT_LEFT' = yes ] && [ '$E6' = y ]"

nb needslogin 0 needslogin key none
E7=$(has_err && echo y)
run_test "NBR-07" "up exits 0 but daemon stays NeedsLogin: exit 1, key KEPT, err line" \
  "[ '$RC' = 1 ] && [ '$BOOT_LEFT' = yes ] && [ '$E7' = y ]"

nb needslogin 0 connecting key none
run_test "NBR-08" "up exits 0 but no NetBird IP: exit 1, key KEPT" \
  "[ '$RC' = 1 ] && [ '$BOOT_LEFT' = yes ]"

nb down 0 joined key none
run_test "NBR-09" "daemon not answering + boot key: exit 1 (retry), key KEPT, no up" \
  "[ '$RC' = 1 ] && [ '$BOOT_LEFT' = yes ] && [ -z '$UPS' ]"

if [ "$(id -u)" != 0 ]; then
  # Join confirmed, but the boot partition refuses the delete -> loud, exit 1.
  printf 'needslogin\n' > "$W/state"; printf '0\n' > "$W/up_rc"; printf 'joined\n' > "$W/after_up"
  rm -rf "$W/ro"; mkdir -p "$W/ro"; printf '%s\n' "$BOOT_FAKE" > "$W/ro/ga-netbird-setup-key"; chmod 555 "$W/ro"
  OUT="$(PATH="$W/bin:$PATH" GA_NETBIRD_BIN="$W/bin/netbird" GA_CURL_BIN="$W/bin/curl" \
    GA_NETBIRD_BOOT_KEY="$W/ro/ga-netbird-setup-key" GA_NETBIRD_BAKED_KEY="$W/none" \
    GA_NETBIRD_REACH_TIMEOUT=0 GA_NETBIRD_CONFIRM_TIMEOUT=0 "$REG" 2>&1)"; RC=$?
  printf '%s\n' "$OUT" >> "$W/all.out"
  E10=$(has_err && echo y)
  run_test "NBR-10" "join confirmed but the key file cannot be removed: exit 1 + err line" \
    "[ '$RC' = 1 ] && [ '$E10' = y ]"
  chmod 755 "$W/ro"
else
  echo "  SKIP  NBR-10: root ignores directory permissions"
fi

echo "── MUST-BE-LOUD (no key -> error, no crash loop) ──"
nb needslogin 0 joined none none
E11=$(has_err && echo y)
N11=$(printf '%s\n' "$OUT" | grep -c "ga-netbird-setup-key")
run_test "NBR-11" "no key anywhere: exit 78, err line naming the boot-partition file, no up" \
  "[ '$RC' = 78 ] && [ '$E11' = y ] && [ '$N11' -ge 1 ] && [ -z '$UPS' ]"
run_test "NBR-12" "unit retries failures but not 78 (Restart=on-failure + RestartPreventExitStatus=78)" \
  "grep -qx 'Restart=on-failure' '$UNIT' && grep -qx 'RestartPreventExitStatus=78' '$UNIT'"
run_test "NBR-13" "unit has no ConditionPathExists (a skipped unit is silent)" \
  "! grep -q '^ConditionPathExists=' '$UNIT'"
run_test "NBR-14" "unit orders after the boot partition mount (RequiresMountsFor=/mnt/boot)" \
  "grep -qx 'RequiresMountsFor=/mnt/boot' '$UNIT'"

echo "── FALLBACK (baked key, until the image stops baking) ──"
nb needslogin 0 joined none key
run_test "NBR-15" "no boot key, baked key: up got the baked key, exit 0" \
  "[ '$RC' = 0 ] && [ '$UPS' = baked ] && [ -f '$W/rootfs/setup-key' ]"

nb needslogin 0 joined empty key
E16=$(has_err && echo y)
run_test "NBR-16" "unusable boot key file: err line, falls back to the baked key" \
  "[ '$RC' = 0 ] && [ '$UPS' = baked ] && [ '$E16' = y ]"

nb needslogin 0 joined key key
run_test "NBR-17" "both keys present: the boot-partition key wins and is deleted" \
  "[ '$RC' = 0 ] && [ '$UPS' = boot ] && [ '$BOOT_LEFT' = no ]"

echo "── NEVER ──"
run_test "NBR-18" "no output of any case printed a key value" \
  "! grep -qF -e '$BOOT_FAKE' -e '$BAKED_FAKE' '$W/all.out'"
run_test "NBR-19" "the script's default boot-partition path is $WANT_BOOT_DEFAULT" \
  "grep -qF 'BOOT_KEY_FILE=\"\${GA_NETBIRD_BOOT_KEY:-$WANT_BOOT_DEFAULT}\"' '$REG'"

suite_end
