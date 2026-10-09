# shellcheck shell=bash
# go-toolchain.sh — keep every Go binary in the image on buildroot's ONE Go toolchain.
# Sourced by scripts/ga_build.sh and tests/ga_tests/run_build_tests.sh. Bash.
# No side effects on load.
#
# WHY THIS FILE EXISTS
#   Buildroot does not rebuild a package when the toolchain under it changes.
#   #710 (2026-10-08) moved host-go from 1.26.5 to 1.26.8. The next `update`
#   bakes recompiled only the Go packages whose OWN version had moved (docker,
#   containerd) or that ga_build.sh force-dircleans (telegraf). netbird, os-agent
#   and runc kept their 2026-08-20 build dirs, so BOSv1.5.0-rc4 shipped them
#   built with go1.26.5 next to six binaries built with go1.26.8. Nothing
#   compared the two, and every gate was green.
#
#   Two halves, both here so the build and its test read the same definition:
#     * the MECHANISM (ga_go_rebuild_if_toolchain_changed): ga_build.sh records
#       the Go version that built the Go packages; when buildroot's GO_VERSION
#       no longer matches the record, it dircleans every enabled package that
#       depends on host-go before the build.
#     * the CHECK (ga_go_toolchain_verdict): the build-test suite reads the Go
#       version embedded in every Go binary in target/ and fails when one
#       differs from GO_VERSION.
#
#   Fixtures: tests/ga_tests/build/go_toolchain/selftest.sh (run in CI, lint.yml)
#   drives the LIVE verdict function over must-flag / must-pass scan outputs.

# ga_go_expected_version BUILDROOT_DIR — prints buildroot's pinned GO_VERSION
# (e.g. 1.26.8) from package/go/go.mk. The expected value comes from the SOURCE,
# never from the build output it is compared with. Exit 1, nothing printed,
# when the file or the assignment is missing or malformed.
ga_go_expected_version() {
  local _mk="${1:-}/package/go/go.mk" _v
  [[ -f "$_mk" ]] || return 1
  _v="$(sed -n -E 's/^GO_VERSION[[:space:]]*=[[:space:]]*([0-9]+\.[0-9]+(\.[0-9]+)?)[[:space:]]*$/\1/p' "$_mk" | head -n 1)"
  [[ -n "$_v" ]] || return 1
  printf '%s\n' "$_v"
}

# ga_go_toolchain_verdict EXPECTED — reads `go version <dir>` output on stdin
# (lines "PATH: goX.Y.Z[ suffix]") and judges it against EXPECTED (X.Y.Z).
#   stdout: one line per offender, "PATH: goA.B.C (expected goX.Y.Z)"
#   stderr: nothing
#   exit 0  every scanned binary embeds exactly goEXPECTED
#   exit 1  at least one binary embeds a different (or unreadable) version
#   exit 2  nothing to judge: EXPECTED empty/malformed, or ZERO binaries scanned
#           (a scan over nothing is a failure, not a pass)
# The comparison is on the whole version token: go1.26.80 is NOT go1.26.8, and
# a "devel" or missing version is an offender, not a pass.
# The scanned count is written to the variable GA_GO_SCANNED for the caller.
ga_go_toolchain_verdict() {
  local _exp="${1:-}" _line _path _ver _bad=0
  GA_GO_SCANNED=0
  [[ "$_exp" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || return 2
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    [[ -n "${_line//[[:space:]]/}" ]] || continue
    # `go version` prints "PATH: VERSION"; a path may itself contain ": ".
    _path="${_line%: *}"
    _ver="${_line##*: }"
    if [[ "$_path" == "$_line" ]]; then
      # Not a scan line at all (e.g. an error message): unreadable = offender.
      printf '%s (unparseable scan line; expected go%s)\n' "$_line" "$_exp"
      _bad=1
      continue
    fi
    GA_GO_SCANNED=$((GA_GO_SCANNED + 1))
    _ver="${_ver%% *}"          # drop " X:experiment" style suffixes
    if [[ "$_ver" != "go${_exp}" ]]; then
      printf '%s: %s (expected go%s)\n' "$_path" "${_ver:-<none>}" "$_exp"
      _bad=1
    fi
  done
  (( GA_GO_SCANNED > 0 )) || return 2
  return "$_bad"
}

# ga_go_scan TARGET_DIR GO_BIN — prints "PATH: goX.Y.Z" for every Go binary
# under TARGET_DIR, using `go version DIR` (which walks the tree and reports
# only recognised Go executables). Paths are made relative to TARGET_DIR.
# Exit 1 when GO_BIN is not executable — the caller must fail, not skip.
ga_go_scan() {
  local _t="${1:-}" _go="${2:-}"
  [[ -d "$_t" && -x "$_go" ]] || return 1
  # GOTOOLCHAIN=local: never let the reader download another toolchain.
  GOTOOLCHAIN=local "$_go" version "$_t" 2>/dev/null | sed "s#^${_t%/}/##"
}

# ga_go_packages OUT BR2_EXTERNAL_PATH — prints the enabled TARGET packages
# that depend on host-go (every golang-package, plus anything else that builds
# with the host Go toolchain), one per line, lowercase buildroot names.
ga_go_packages() {
  local _out="${1:-}" _ext="${2:-}" _vars _pkgs _p _up _deps
  _vars="$(make -s O="$_out" BR2_EXTERNAL="$_ext" printvars \
             VARS='PACKAGES %_DEPENDENCIES' 2>/dev/null)" || return 1
  _pkgs="$(printf '%s\n' "$_vars" | sed -n 's/^PACKAGES=//p')"
  [[ -n "$_pkgs" ]] || return 1
  for _p in $_pkgs; do
    [[ "$_p" == host-* ]] && continue
    _up="$(printf '%s' "$_p" | tr 'a-z-' 'A-Z_')"
    _deps="$(printf '%s\n' "$_vars" | sed -n "s/^${_up}_DEPENDENCIES=//p")"
    case " $_deps " in *" host-go "*) printf '%s\n' "$_p" ;; esac
  done
}

# Where ga_build.sh records the Go version that built the Go packages in OUT.
ga_go_stamp_file() { printf '%s/.ga-go-toolchain\n' "${1:-}"; }

# ga_go_rebuild_if_toolchain_changed OUT BR2_EXTERNAL_PATH EXPECTED
# Call after `make <defconfig>` on a reused OUT (update/partial/kernel). When
# the recorded version differs from EXPECTED — or there is no record, which is
# every tree that predates this mechanism — every enabled host-go package is
# dircleaned so the main build recompiles it with the current toolchain.
# Loud on purpose: a rebuild costs minutes; a silent stale binary cost a release.
ga_go_rebuild_if_toolchain_changed() {
  local _out="${1:-}" _ext="${2:-}" _exp="${3:-}" _stamp _rec _pkgs _p
  [[ -n "$_exp" ]] || { echo "ERROR: go-toolchain: no expected Go version" >&2; return 1; }
  _stamp="$(ga_go_stamp_file "$_out")"
  _rec="$(cat "$_stamp" 2>/dev/null || true)"
  if [[ "$_rec" == "$_exp" ]]; then
    echo "go-toolchain: Go packages in this tree were built with go${_exp} (= buildroot GO_VERSION) — no rebuild needed"
    return 0
  fi
  _pkgs="$(ga_go_packages "$_out" "$_ext")" || {
    echo "ERROR: go-toolchain: could not list the host-go packages (make printvars failed)" >&2
    return 1
  }
  if [[ -z "$_pkgs" ]]; then
    echo "go-toolchain: no enabled package depends on host-go — nothing to rebuild"
    return 0
  fi
  echo "WARNING: go-toolchain: Go packages in this tree were built with ${_rec:+go}${_rec:-<unrecorded toolchain>}, buildroot now pins go${_exp}."
  echo "WARNING: go-toolchain: dircleaning every host-go package so it is recompiled: ${_pkgs//$'\n'/ }"
  rm -f "$_stamp"
  for _p in $_pkgs; do
    make O="$_out" BR2_EXTERNAL="$_ext" "${_p}-dirclean" || return 1
  done
}

# ga_go_record_toolchain OUT EXPECTED — call only after the main build succeeded.
ga_go_record_toolchain() {
  printf '%s\n' "${2:?}" > "$(ga_go_stamp_file "${1:?}")"
}
