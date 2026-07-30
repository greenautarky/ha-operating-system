#!/bin/bash
# mutate.sh — failure injection for the build-test suite.
#
# WHY
# ---
# `run_build_tests.sh` is ~300 assertions. Green tells you nothing about whether
# those assertions can go red. Guards written on 2026-07-30 could not:
#
#   * a disclosure override placed in a later `if: failure()` step — a failed
#     step fails the job whatever runs after it, so the override was decoration
#   * a dev/prod signing selector keyed on DEPLOYMENT, which is hardcoded
#     "production" and does not change between build modes, so the separation
#     was inert while looking correct
#
# Both were found by breaking the thing on purpose and watching. Neither would
# have been found by reading. Six further checks in the device suites turned out
# to be incapable of passing at all — the same blindness, mirrored.
#
# WHAT IT DOES
# ------------
# Copies a known-good build output, injects ONE defect, runs the suite against
# the copy, and asserts that THE EXPECTED CHECK fails.
#
# "Something failed" is not the assertion. A mutation that trips five checks
# tells you the suite is noisy, not that the guard works. Each mutation names
# the check that must go red, and the run fails if a DIFFERENT check catches it
# — because then the guard under test is still unproven and you have learned the
# wrong thing.
#
# WHAT THE FIRST VERSION GOT WRONG (kept here so it is not repeated)
# ------------------------------------------------------------------
#   * It copied the whole repo with `cp -a "$SCRIPT_DIR/../.."`. That includes
#     ga_output — the very thing the comment above the copy warned was too
#     large — AND the OTA signing keys, which live in the repo root on the build
#     host. Seven mutations meant seven copies of the production signing key in
#     /tmp, with cleanup only as the last statement of the loop body: a Ctrl-C,
#     a kill or an OOM left it there. Now: an explicit allowlist of source
#     directories, an explicit refusal to copy anything matching *.pem or *.key,
#     and a `trap ... EXIT` so an interrupted run still cleans up.
#   * The source mutations could never be caught, because the suite resolved its
#     source root to /build regardless of where the copy was. It now honours
#     GA_SRC_ROOT, which is what makes those mutations reachable at all.
#
# Usage:  ./mutate.sh <output_dir> [mutation-name ...]
#         ./mutate.sh /build/ga_output            # all mutations
#         ./mutate.sh /build/ga_output no-marker  # just one
#
# Exit code: number of mutations that did NOT produce their expected failure.
set -uo pipefail

SRC_OUT="${1:?Usage: $0 <output_dir> [mutation ...]}"
shift || true
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SUITE="${SCRIPT_DIR}/run_build_tests.sh"

[[ -d "$SRC_OUT/target" ]] || { echo "ERROR: $SRC_OUT/target missing — need a real build output" >&2; exit 2; }
[[ -x "$SUITE" ]] || { echo "ERROR: $SUITE not executable" >&2; exit 2; }

GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[0;33m' RESET='\033[0m'
[[ -t 1 ]] || { GREEN=''; RED=''; YELLOW=''; RESET=''; }

# Cleanup must survive an interrupt. The first version cleaned up only on the
# normal path, and what it was leaving behind was signing material.
WORKDIRS=()
cleanup() { local d; for d in "${WORKDIRS[@]:-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf "$d"; done; }
trap cleanup EXIT INT TERM

# Only the source trees the SRC-* checks actually read. Never the repo root:
# that is where ga_output and the signing keys live.
SRC_SUBDIRS=(buildroot-external buildroot-ihost tests scripts)

copy_source() {
    local dest="$1" d
    mkdir -p "$dest"
    for d in "${SRC_SUBDIRS[@]}"; do
        [[ -d "${REPO_ROOT}/${d}" ]] || continue
        cp -a "${REPO_ROOT}/${d}" "${dest}/" || {
            echo "ERROR: failed to copy ${d} — refusing to mutate a partial tree" >&2
            return 1
        }
    done
    # Belt and braces: if a PRIVATE key ever moves into one of those
    # directories, this is where it stops. A copy of signing material in /tmp is
    # not acceptable even for a second.
    #
    # By CONTENT, not by extension. The first version swept every *.pem, which
    # also removed ota/dev-ca.pem — a public X.509 certificate, not a secret,
    # and the baseline RAUC-KEYRING-01 derives its expected trust set from.
    # Every mutated run therefore failed that check as well, on all six
    # mutations, for a reason that had nothing to do with the mutation. This
    # script's own rule says a mutation tripping several checks measures noise
    # rather than the guard, so the safety measure was quietly degrading the
    # signal it exists to protect.
    local swept=0 f
    while IFS= read -r f; do
        if grep -qs 'PRIVATE KEY' "$f"; then rm -f "$f"; swept=$((swept+1)); fi
    done < <(find "$dest" -type f \( -name '*.pem' -o -name '*.key' \) 2>/dev/null)
    (( swept > 0 )) && echo "  note: removed ${swept} private key file(s) from the scratch copy"
    return 0
}

# name | expected check id | what we break
#
# Keep the injected defect as close as possible to the real failure. Deleting a
# file the check reads proves the check reads it; it does not prove the check
# would notice the file being WRONG. Where a wrong value is the realistic
# failure, mutate the value.
MUTATIONS="
no-marker|CFG-49a|remove the ethernet-force marker from the boot artefact
no-sup-mount|SRC-20|strip the ga-services.conf mount from the Supervisor launcher
private-key|SRC-18|plant a private key in the shipped rootfs
post-seal-write|SRC-19|write a file into target/ after the rootfs was sealed
hardcoded-signkey|SRC-22|put a literal signing key path back in the genimage config
bridge-residue|SRC-21|put the retired CA bridge flag back in meta
"

apply_mutation() {
    local name="$1" out="$2" src="$3"
    case "$name" in
        no-marker)         rm -f "$out/images/boot/ga-ethernet-force" ;;
        no-sup-mount)      grep -v 'GA_SERVICES_MOUNT' "$out/target/usr/sbin/hassos-supervisor" \
                             > "$out/target/usr/sbin/.tmp" && mv "$out/target/usr/sbin/.tmp" "$out/target/usr/sbin/hassos-supervisor" ;;
        # The PEM header is assembled at runtime, not written literally. The
        # file this produces is identical either way — but the SOURCE then does
        # not contain a string that the disclosure gate (correctly) treats as a
        # credential shape. Changing the code is the right answer to a gate hit;
        # reaching for the override to keep a literal that has no reason to be
        # literal is how an override becomes reflex.
        private-key)       mkdir -p "$out/target/etc/ssh"
                           _pem='PRIVATE KEY'
                           printf -- '-----BEGIN %s-----\nMUTATION\n-----END %s-----\n' "$_pem" "$_pem" \
                             > "$out/target/etc/ssh/injected.key" ;;
        post-seal-write)   touch "$out/target/etc/injected-after-seal" ;;
        hardcoded-signkey) sed -i 's|key = "${GA_SIGN_KEY.*}"|key = "/build/key.pem"|' \
                             "$src/buildroot-external/genimage/image-raucb-nospl.cfg" ;;
        bridge-residue)    printf 'GA_LEGACY_CA_BRIDGE="false"\n' >> "$src/buildroot-external/meta" ;;
        *) return 1 ;;
    esac
}

WANTED=("$@")
want() {
    [[ ${#WANTED[@]} -eq 0 ]] && return 0
    local w; for w in "${WANTED[@]}"; do [[ "$w" == "$1" ]] && return 0; done; return 1
}

echo "=== Failure injection against $SRC_OUT ==="
echo

# Baseline first. Mutating a build whose suite is already red proves nothing —
# you cannot tell an injected failure from a pre-existing one. This is also the
# reason the first version of this script never completed a run: the baseline
# was red because of a defect in the keyring audit, not in the build.
base_out="$("$SUITE" "$SRC_OUT" 2>/dev/null)"
base_fail=$(printf '%s' "$base_out" | grep -cE '^\s+FAIL' || true)
if [[ "$base_fail" -ne 0 ]]; then
    echo -e "${RED}ABORT${RESET}  the suite is already failing ${base_fail} check(s) on the unmutated build:"
    printf '%s' "$base_out" | grep -E '^\s+FAIL' | sed -E 's/^\s+/         /' | head -10
    echo "       Injected failures could not be told apart from these. Fix the baseline first."
    exit 2
fi
echo -e "${GREEN}baseline${RESET}  0 failures on the unmutated build — injected failures will be unambiguous"

# Second baseline: the noise floor of the SCRATCH COPY itself.
#
# The copy is deliberately partial — it holds target/, images/boot and
# images/configs, not the disk image or the full build tree — so checks that
# read anything else fail on it no matter what is mutated. Reporting those as
# side effects of every mutation makes the output read as though each defect
# tripped four checks, which is the noise this harness is supposed to
# distinguish itself from.
#
# Measure it once rather than hardcoding a list: a hardcoded exclusion would
# silently grow stale and start hiding real side effects.
_nf_work="$(mktemp -d)"; WORKDIRS+=("$_nf_work")
mkdir -p "$_nf_work/images" "$_nf_work/target"
cp -a "$SRC_OUT/target" "$_nf_work/" 2>/dev/null
cp -a "$SRC_OUT/images/boot" "$_nf_work/images/" 2>/dev/null
cp -a "$SRC_OUT/images/configs" "$_nf_work/images/" 2>/dev/null
touch "$_nf_work/images/rootfs.erofs"
NOISE="$("$SUITE" "$_nf_work" 2>/dev/null | grep -E '^\s+FAIL' \
         | sed -E 's/^[[:space:]]+FAIL[[:space:]]+([A-Za-z0-9-]+):.*/\1/' | sort -u | tr '\n' ' ')"
rm -rf "$_nf_work"
if [[ -n "${NOISE// /}" ]]; then
    echo -e "${YELLOW}noise floor${RESET}  the scratch copy cannot satisfy: ${NOISE}"
    echo "             (partial copy by design — these are subtracted from side effects below)"
fi
echo

not_caught=0
while IFS='|' read -r name expect desc; do
    [[ -n "$name" ]] || continue
    want "$name" || continue

    work="$(mktemp -d)"; srcwork="$(mktemp -d)"
    WORKDIRS+=("$work" "$srcwork")

    # Only what the suite reads. A full copy of ga_output is tens of GB.
    mkdir -p "$work/images" "$work/target"
    cp -a "$SRC_OUT/target" "$work/" 2>/dev/null
    cp -a "$SRC_OUT/images/boot" "$work/images/" 2>/dev/null
    cp -a "$SRC_OUT/images/configs" "$work/images/" 2>/dev/null
    touch "$work/images/rootfs.erofs"
    copy_source "$srcwork/repo" || { echo -e "${RED}ERROR${RESET}  $name — source copy failed"; not_caught=$((not_caught+1)); continue; }

    if ! apply_mutation "$name" "$work" "$srcwork/repo"; then
        echo -e "${YELLOW}SKIP${RESET}   $name — no injector defined"
        rm -rf "$work" "$srcwork"; continue
    fi

    # GA_SRC_ROOT is what makes the source mutations reachable: without it the
    # suite reads the real tree and every source mutation reports "not caught"
    # while the guard is in fact fine.
    out="$(GA_SRC_ROOT="$srcwork/repo" "$srcwork/repo/tests/ga_tests/run_build_tests.sh" "$work" 2>/dev/null)"
    # [A-Za-z0-9-] not [A-Z0-9-]: check ids are not all upper case (CFG-49a),
    # and a failed substitution leaves the whole FAIL line in the id list,
    # which then reads as a bizarre extra "check".
    fails="$(printf '%s' "$out" | grep -E '^\s+FAIL' \
             | sed -E 's/^[[:space:]]+FAIL[[:space:]]+([A-Za-z0-9-]+):.*/\1/' | sort -u | tr '\n' ' ')"

    if printf '%s' "$fails" | grep -qw "$expect"; then
        # Side effects = what this mutation broke BEYOND the noise floor.
        extra="$(printf '%s' "$fails" | tr ' ' '\n' | grep -v "^${expect}$" | grep -v '^$' \
                 | grep -vxF -f <(printf '%s\n' $NOISE) 2>/dev/null | tr '\n' ' ')"
        if [[ -n "$extra" ]]; then
            echo -e "${GREEN}CAUGHT${RESET} $name -> $expect  ${YELLOW}(also: $extra)${RESET}"
        else
            echo -e "${GREEN}CAUGHT${RESET} $name -> $expect"
        fi
    elif [[ -n "$fails" ]]; then
        # The wrong check caught it. The guard under test is STILL unproven.
        echo -e "${RED}WRONG${RESET}  $name -> expected $expect, but got: $fails"
        echo "       $desc"
        echo "       The guard under test did not fire. Something else did."
        not_caught=$((not_caught + 1))
    else
        echo -e "${RED}MISSED${RESET} $name -> nothing failed. $expect does not guard: $desc"
        not_caught=$((not_caught + 1))
    fi
    rm -rf "$work" "$srcwork"
done <<< "$MUTATIONS"

echo
if [[ "$not_caught" -eq 0 ]]; then
    echo -e "${GREEN}All mutations were caught by the check that is supposed to catch them.${RESET}"
else
    echo -e "${RED}${not_caught} mutation(s) not caught by their own guard — those guards are unproven.${RESET}"
fi
exit "$not_caught"
