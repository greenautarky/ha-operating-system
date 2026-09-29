#!/bin/sh
# ga-share-publish security regression suite.
#
# Verifies the symlink-follow hardening for the host->addon /share bridge
# ("Vuln-2"): a root write to a target inside the container-writable /share
# directory must NOT follow a symlink a hostile addon planted at that path,
# i.e. it must never write through it to an arbitrary root-owned file.
#
# Pure host-side: needs only sh + coreutils/busybox. No device required.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "ga-share-publish (/share symlink hardening)"

# Locate the helper: installed path on device, overlay path in-repo.
PUB="/usr/libexec/ga-share-publish"
[ -x "$PUB" ] || PUB="$SCRIPT_DIR/../../../buildroot-external/rootfs-overlay/usr/libexec/ga-share-publish"

run_test "GSP-01" "helper present + executable" "test -x '$PUB'"

WORK="$(mktemp -d 2>/dev/null || echo /tmp/gsp_$$)"
SHARE="$WORK/share"        # stand-in for the container-writable /share dir
STAGE="$WORK/stage"        # root-only staging dir (same filesystem as target)
mkdir -p "$SHARE" "$STAGE"

# --- basic publish -----------------------------------------------------------
printf 'hello\n' | GA_SHARE_STAGE_DIR="$STAGE" "$PUB" "$SHARE/basic.json" 2>/dev/null
run_test "GSP-02" "publishes stdin to target" \
  "[ \"\$(cat '$SHARE/basic.json' 2>/dev/null)\" = hello ]"
run_test "GSP-03" "target is a regular file (not a symlink)" \
  "[ -f '$SHARE/basic.json' ] && [ ! -L '$SHARE/basic.json' ]"
run_test "GSP-04" "default mode is 0644" \
  "[ \"\$(stat -c '%a' '$SHARE/basic.json' 2>/dev/null)\" = 644 ]"

# explicit mode
printf 'secret\n' | GA_SHARE_STAGE_DIR="$STAGE" "$PUB" "$SHARE/moded.json" 0600 2>/dev/null
run_test "GSP-05" "explicit mode is applied (0600)" \
  "[ \"\$(stat -c '%a' '$SHARE/moded.json' 2>/dev/null)\" = 600 ]"

# empty stdin -> empty file (the ga-crash-marker case)
: | GA_SHARE_STAGE_DIR="$STAGE" "$PUB" "$SHARE/empty.marker" 2>/dev/null
run_test "GSP-06" "empty stdin creates an empty regular file" \
  "[ -f '$SHARE/empty.marker' ] && [ ! -s '$SHARE/empty.marker' ] && [ ! -L '$SHARE/empty.marker' ]"

# --- THE security property: a pre-planted symlink is NOT followed ------------
# Attacker (a share:rw addon, uid 0 in its container) plants a symlink at the
# target path pointing at a root-owned file OUTSIDE /share. The publish must
# leave that file untouched and land its bytes at the literal target path.
VICTIM="$WORK/victim_root_file"
printf 'ORIGINAL-ROOT-CONTENT\n' > "$VICTIM"
ln -sf "$VICTIM" "$SHARE/attacked.json"
printf 'NEW-CONTENT\n' | GA_SHARE_STAGE_DIR="$STAGE" "$PUB" "$SHARE/attacked.json" 2>/dev/null

run_test "GSP-10" "symlink at target is NOT followed (victim file untouched)" \
  "[ \"\$(cat '$VICTIM')\" = ORIGINAL-ROOT-CONTENT ]"
run_test "GSP-11" "target replaced by a real file (planted symlink gone)" \
  "[ -f '$SHARE/attacked.json' ] && [ ! -L '$SHARE/attacked.json' ]"
run_test "GSP-12" "published bytes landed at the real target path" \
  "[ \"\$(cat '$SHARE/attacked.json')\" = NEW-CONTENT ]"

# --- a symlink to a DIRECTORY appearing between the cleanup and the rename ---
# ga-share-publish removes a symlink at the target and then renames. Something
# else can create a new symlink in that window. A stub `rm` makes that window
# deterministic: it removes the target and immediately puts a symlink to a
# directory there. The rename must still only ever produce the literal target
# path — nothing may land inside the linked directory.
RACE_DIR="$WORK/other_dir"; mkdir -p "$RACE_DIR"
STUB="$WORK/stub"; mkdir -p "$STUB"
REAL_RM="$(command -v rm)"
cat > "$STUB/rm" <<EOF
#!/bin/sh
"$REAL_RM" "\$@"
for a in "\$@"; do [ "\$a" = "$SHARE/raced.json" ] && ln -s "$RACE_DIR" "\$a"; done
exit 0
EOF
chmod +x "$STUB/rm"
race_publish() {  # <PATH prefix>
  "$REAL_RM" -rf "$SHARE/raced.json" "$RACE_DIR"/* "$RACE_DIR"/.[!.]* 2>/dev/null
  ln -s "$VICTIM" "$SHARE/raced.json"
  printf 'RACED\n' | PATH="$1$STUB:$PATH" GA_SHARE_STAGE_DIR="$STAGE" "$PUB" "$SHARE/raced.json" 2>/dev/null
}
race_publish ""
run_test "GSP-13" "a symlink to a directory re-created before the rename is not followed (host mv)" \
  "[ -z \"\$(ls -A '$RACE_DIR')\" ] && [ \"\$(cat '$VICTIM')\" = ORIGINAL-ROOT-CONTENT ]"
if command -v busybox >/dev/null 2>&1; then
  BBMV="$WORK/bbmv"; mkdir -p "$BBMV"; ln -s "$(command -v busybox)" "$BBMV/mv"
  race_publish "$BBMV:"
  run_test "GSP-14" "a symlink to a directory re-created before the rename is not followed (BusyBox mv)" \
    "[ -z \"\$(ls -A '$RACE_DIR')\" ] && [ \"\$(cat '$VICTIM')\" = ORIGINAL-ROOT-CONTENT ]"
else
  skip_test "GSP-14" "same, BusyBox mv" "busybox not installed"
fi

rm -rf "$WORK" 2>/dev/null

suite_end
