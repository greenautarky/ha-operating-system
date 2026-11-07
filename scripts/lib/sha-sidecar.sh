# shellcheck shell=bash
# sha-sidecar.sh -- write the <file>.sha256 sidecar of a bake output. Sourced by
# scripts/ga_build.sh. No side effects on load.  (Odoo #1657)
#
# The sidecar holds `<sha256>  <basename>`, so `sha256sum -c <file>.sha256`
# works next to the file. It used to hold the container path
# (/build/ga_output/images/<file>), which made `sha256sum -c` fail anywhere else.
# Consumers that read only token 1 (awk/cut) are unaffected.
#   Fixtures: tests/ga_tests/build/sha_sidecar/selftest.sh (run in CI).

# ga_write_sha_sidecar FILE -- writes FILE.sha256 as "<sha256>  <basename>".
ga_write_sha_sidecar() {
  local f="${1:?ga_write_sha_sidecar: file}" d b
  d="$(dirname -- "$f")"; b="$(basename -- "$f")"
  [[ -f "$f" ]] || { echo "ga_write_sha_sidecar: no such file: $f" >&2; return 1; }
  ( cd -- "$d" && sha256sum -- "$b" > "${b}.sha256" )
}
