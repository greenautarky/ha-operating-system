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

# ga_go_floor_version EXTERNAL_DIR — prints GA_GO_VERSION_FLOOR from
# EXTERNAL_DIR/go-floor.mk (the GA carry that lifts buildroot's Go to a fixed
# release; see that file). Exit 1, nothing printed, when the file or the
# assignment is missing or malformed.
ga_go_floor_version() {
  local _mk="${1:-}/go-floor.mk" _v
  [[ -f "$_mk" ]] || return 1
  _v="$(sed -n -E 's/^GA_GO_VERSION_FLOOR[[:space:]]*=[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$/\1/p' "$_mk" | head -n 1)"
  [[ -n "$_v" ]] || return 1
  printf '%s\n' "$_v"
}

# ga_go_expected_version BUILDROOT_DIR [EXTERNAL_DIR] — prints the Go version
# the build uses: GO_VERSION from package/go/go.mk, raised to GA_GO_VERSION_FLOOR
# (EXTERNAL_DIR/go-floor.mk) when that is higher. The same rule as go-floor.mk
# (highest wins, sort -V), so a submodule bump past the floor is followed, never
# downgraded. The expected value comes from the SOURCE, never from the build
# output it is compared with. Exit 1, nothing printed, when go.mk or its
# assignment is missing or malformed, or when EXTERNAL_DIR is given, has a
# go-floor.mk, and that file's floor is malformed.
ga_go_expected_version() {
  local _mk="${1:-}/package/go/go.mk" _v _f
  [[ -f "$_mk" ]] || return 1
  _v="$(sed -n -E 's/^GO_VERSION[[:space:]]*=[[:space:]]*([0-9]+\.[0-9]+(\.[0-9]+)?)[[:space:]]*$/\1/p' "$_mk" | head -n 1)"
  [[ -n "$_v" ]] || return 1
  if [[ -n "${2:-}" && -f "${2}/go-floor.mk" ]]; then
    _f="$(ga_go_floor_version "$2")" || return 1
    _v="$(printf '%s\n%s\n' "$_v" "$_f" | sort -V | tail -n 1)"
  fi
  printf '%s\n' "$_v"
}

# ga_go_floor_verdict FLOOR — reads `go version <dir>` output on stdin (lines
# "PATH: goX.Y.Z[ suffix]") and fails every binary OLDER than FLOOR (X.Y.Z).
# Unlike ga_go_toolchain_verdict (all binaries on ONE version), this holds the
# build to a pinned minimum, so a toolchain that is consistent but old is red.
#   stdout: one line per offender, "PATH: goA.B.C (below floor goX.Y.Z)"
#   exit 0  every scanned binary embeds a Go version >= FLOOR
#   exit 1  at least one binary is older, "devel", or unreadable
#   exit 2  nothing to judge: FLOOR empty/malformed, or ZERO binaries scanned
# The scanned count is written to the variable GA_GO_SCANNED for the caller.
ga_go_floor_verdict() {
  local _floor="${1:-}" _line _path _ver _bad=0 _low
  GA_GO_SCANNED=0
  [[ "$_floor" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 2
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    [[ -n "${_line//[[:space:]]/}" ]] || continue
    _path="${_line%: *}"
    _ver="${_line##*: }"
    if [[ "$_path" == "$_line" ]]; then
      printf '%s (unparseable scan line; floor go%s)\n' "$_line" "$_floor"
      _bad=1
      continue
    fi
    GA_GO_SCANNED=$((GA_GO_SCANNED + 1))
    _ver="${_ver%% *}"
    if [[ ! "$_ver" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
      printf '%s: %s (not a release version; floor go%s)\n' "$_path" "${_ver:-<none>}" "$_floor"
      _bad=1
      continue
    fi
    # go1.26 (no patch) is the .0 release: compare it as 1.26.0.
    [[ "${_ver#go}" =~ ^[0-9]+\.[0-9]+$ ]] && _ver="${_ver}.0"
    _low="$(printf '%s\n%s\n' "${_ver#go}" "$_floor" | sort -V | head -n 1)"
    if [[ "$_low" != "$_floor" ]]; then
      printf '%s: %s (below floor go%s)\n' "$_path" "$_ver" "$_floor"
      _bad=1
    fi
  done
  (( GA_GO_SCANNED > 0 )) || return 2
  return "$_bad"
}

# ga_go_toolchain_verdict EXPECTED — reads `go version <dir>` output on stdin
# (lines "PATH: goX.Y.Z[ suffix]") and judges it against EXPECTED (X.Y.Z).
#   stdout: one line per offender, "PATH: goA.B.C (expected goX.Y.Z)"
#   stderr: nothing
#   exit 0  every scanned binary embeds exactly goEXPECTED
#   exit 1  at least one binary embeds a different (or unreadable) version
#   exit 2  nothing to judge: EXPECTED empty/malformed, or ZERO binaries scanned
#           (a scan over nothing is a failure, not a pass)
# The comparison uses the whole version string (go1.26.80 is NOT go1.26.8), and
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

# ga_go_modfloor_list EXTERNAL_DIR — prints the module floors from
# EXTERNAL_DIR/go-modfloor.mk, one "module version" pair per line (the same
# GA_GO_MODFLOOR lines scripts/go-modbump.sh lifts the vendored modules to).
# Exit 1, nothing printed, when the file is missing or holds no floor line.
ga_go_modfloor_list() {
  local _mk="${1:-}/go-modfloor.mk" _out
  [[ -f "$_mk" ]] || return 1
  _out="$(sed -n -E 's/^GA_GO_MODFLOOR[[:space:]]*\+?=[[:space:]]*([^[:space:]@]+)@(v[0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$/\1 \2/p' "$_mk")"
  [[ -n "$_out" ]] || return 1
  printf '%s\n' "$_out"
}

# ga_go_modfloor_verdict FLOORS — reads `go version -m <dir>` output on stdin and
# fails every Go binary that embeds a floored module BELOW its floor. FLOORS is
# the text ga_go_modfloor_list prints ("module version" per line). The module
# name is matched whole (golang.org/x/net is not golang.org/x/network), and a
# `=>` replace line overrides the module it follows (the replacement is what
# is linked).
#   stdout: one line per offender, "PATH: MODULE VERSION (below floor VERSION)"
#   exit 0  every scanned binary is at or above every floor it embeds
#   exit 1  at least one binary embeds a floored module below its floor
#   exit 2  nothing to judge: no/malformed FLOORS, or ZERO binaries scanned
# Variables for the caller: GA_GO_SCANNED (binaries), GA_GO_MODS_SEEN (floored
# module entries read - zero over a real image means the reader, not the image,
# is broken).
ga_go_modfloor_verdict() {
  local _floors="${1:-}" _line _cur="" _bad=0 _kind _mod _ver _f _fm _fv _low _last_mod="" _flagged
  local -A _floor=()
  GA_GO_SCANNED=0 GA_GO_MODS_SEEN=0
  while IFS= read -r _f || [[ -n "$_f" ]]; do
    [[ -n "$_f" ]] || continue
    _fm="${_f% *}" _fv="${_f#* }"
    [[ "$_fm" != "$_f" && "$_fm" =~ ^[A-Za-z0-9._/-]+$ && "$_fv" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 2
    _floor["$_fm"]="$_fv"
  done <<<"$_floors"
  (( ${#_floor[@]} > 0 )) || return 2
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    if [[ "$_line" =~ ^[^[:space:]].*:\ go ]]; then          # "PATH: goX.Y.Z" header
      _cur="${_line%: *}"; _last_mod=""; GA_GO_SCANNED=$((GA_GO_SCANNED + 1)); continue
    fi
    [[ "$_line" =~ ^[[:space:]] && -n "$_cur" ]] || continue
    # tab is IFS-whitespace: the leading tab is dropped, fields are kind/module/version/sum
    IFS=$'\t' read -r _kind _mod _ver _ <<<"$_line"
    case "$_kind" in
      dep|mod) _last_mod="$_mod" ;;
      '=>')    # replace line: what is LINKED is this module/version, not the one above
        [[ -n "$_last_mod" && -n "${_floor[$_last_mod]+x}" ]] || continue
        GA_GO_MODS_SEEN=$((GA_GO_MODS_SEEN + 1))
        if [[ "$_mod" != "$_last_mod" ]]; then
          printf '%s: %s replaced by %s %s (cannot be judged against floor %s)\n' "$_cur" "$_last_mod" "$_mod" "${_ver:-<none>}" "${_floor[$_last_mod]}"
          _bad=1; continue
        fi
        _mod="$_last_mod" ;;
      *) continue ;;
    esac
    [[ -n "${_mod:-}" && -n "${_floor[$_mod]+x}" ]] || continue
    [[ "$_kind" == '=>' ]] || GA_GO_MODS_SEEN=$((GA_GO_MODS_SEEN + 1))
    _fv="${_floor[$_mod]}"
    _low="$(printf '%s\n%s\n' "${_ver#v}" "${_fv#v}" | sort -V | head -n 1)"
    if [[ ! "$_ver" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ || ( "${_ver#v}" != "${_fv#v}" && "$_low" != "${_fv#v}" ) ]]; then
      printf '%s: %s %s (below floor %s)\n' "$_cur" "$_mod" "${_ver:-<none>}" "$_fv"
      _bad=1
    fi
  done
  (( GA_GO_SCANNED > 0 )) || return 2
  return "$_bad"
}

# ga_go_scan_mods TARGET_DIR GO_BIN — prints `go version -m` for every Go binary
# under TARGET_DIR (paths relative to TARGET_DIR). Exit 1 when GO_BIN is not
# executable - the caller must fail, not skip.
ga_go_scan_mods() {
  local _t="${1:-}" _go="${2:-}"
  [[ -d "$_t" && -x "$_go" ]] || return 1
  GOTOOLCHAIN=local "$_go" version -m "$_t" 2>/dev/null | sed "s#^${_t%/}/##"
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
    echo "go-toolchain: Go packages in this tree were built with the current Go inputs (${_exp}: toolchain + module floors) — no rebuild needed"
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
  echo "WARNING: go-toolchain: Go packages in this tree were built from Go inputs ${_rec:-<unrecorded>}, the current ones are ${_exp} (toolchain version + vendored-module floors)."
  echo "WARNING: go-toolchain: dircleaning every host-go package so it is recompiled: ${_pkgs//$'\n'/ }"
  rm -f "$_stamp"
  for _p in $_pkgs; do
    make O="$_out" BR2_EXTERNAL="$_ext" "${_p}-dirclean" || return 1
  done
}

# ga_go_stamp_id EXPECTED EXTERNAL_DIR [BUMP_SCRIPT] — the value ga_build.sh
# records (and compares) for the Go packages in an output tree: the Go version
# plus a hash of everything else that decides what is compiled into them - the
# vendored-module floors (go-modfloor.mk), their pinned hashes (go-modfloor.sum)
# and the script that applies them (scripts/go-modbump.sh). Buildroot applies a
# POST_PATCH hook once per package build dir, so on a reused tree a changed floor
# would otherwise never reach netbird/telegraf/docker/containerd. Exit 1 when
# any input is missing: refusing beats recording a stamp that hides a change.
ga_go_stamp_id() {
  local _v="${1:-}" _ext="${2:-}" _bump="${3:-}" _h
  [[ -n "$_v" ]] || return 1
  [[ -n "$_bump" ]] || _bump="$(dirname "${BASH_SOURCE[0]}")/../go-modbump.sh"
  [[ -f "$_ext/go-modfloor.mk" && -f "$_ext/go-modfloor.sum" && -f "$_bump" ]] || return 1
  _h="$(cat "$_ext/go-modfloor.mk" "$_ext/go-modfloor.sum" "$_bump" | sha256sum | cut -c1-12)" || return 1
  printf '%s+modfloor.%s\n' "$_v" "$_h"
}

# ga_go_record_toolchain OUT EXPECTED — call only after the main build succeeded.
ga_go_record_toolchain() {
  printf '%s\n' "${2:?}" > "$(ga_go_stamp_file "${1:?}")"
}
