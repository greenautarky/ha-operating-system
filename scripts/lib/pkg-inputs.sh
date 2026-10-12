# shellcheck shell=bash
# pkg-inputs.sh -- rebuild a buildroot package when OUR patches or configure
# options for it changed. Sourced by scripts/ga_build.sh. Bash. No side effects
# on load.
#
# WHY THIS FILE EXISTS
#   Buildroot decides "already patched / configured / built" from stamp files in
#   the package's build dir. It does not look at the patches in
#   BR2_GLOBAL_PATCH_DIR (buildroot-external/patches/<pkg>/) or at
#   <PKG>_CONF_OPTS again. A reused output tree (the `update` bake) therefore
#   keeps the old, unpatched libglib2 / xz and the old full-plugin fluent-bit
#   for ever, and the bake is green. A fix that never reaches the image is not a
#   fix. Same failure class as the Go toolchain (scripts/lib/go-toolchain.sh).
#
#   ga_build.sh records a fingerprint of those inputs per package after a
#   successful build; when it differs (or there is none), the package is
#   dircleaned before the build. Loud on purpose.
#
#   Fixtures: tests/ga_tests/build/pkg_inputs/selftest.sh (run in CI).

# Packages whose patches live in buildroot-external/patches/ or whose configure
# options are set in buildroot-external/ and must reach the image.
GA_PKG_INPUT_PACKAGES="libglib2 xz fluent-bit"

# ga_pkg_inputs_fingerprint PKG PATCH_ROOT [EXTRA]
# sha256 over EXTRA and every file (name + content) in PATCH_ROOT/PKG.
ga_pkg_inputs_fingerprint() {
  local _pkg="${1:?}" _root="${2:?}" _extra="${3:-}" _f
  {
    printf 'extra:%s\n' "$_extra"
    if [[ -d "$_root/$_pkg" ]]; then
      while IFS= read -r _f; do
        printf '%s %s\n' "$_f" "$(sha256sum < "$_root/$_pkg/$_f" | cut -d' ' -f1)"
      done < <(cd "$_root/$_pkg" && find . -type f | LC_ALL=C sort)
    fi
  } | sha256sum | cut -d' ' -f1
}

ga_pkg_inputs_stamp() { printf '%s/.ga-pkg-inputs/%s\n' "${1:?}" "${2:?}"; }

# ga_pkg_inputs_extra OUT BR2_EXTERNAL_PATH PKG -- the non-patch input of PKG:
# its configure options as buildroot resolved them (empty for packages without).
ga_pkg_inputs_extra() {
  local _out="${1:?}" _ext="${2:?}" _pkg="${3:?}" _up
  case "$_pkg" in
    fluent-bit)
      _up="FLUENT_BIT_CONF_OPTS"
      make -s O="$_out" BR2_EXTERNAL="$_ext" printvars VARS="$_up" 2>/dev/null | sed -n "s/^${_up}=//p"
      ;;
    *) printf '' ;;
  esac
}

# ga_pkg_inputs_rebuild_if_changed OUT BR2_EXTERNAL_PATH PATCH_ROOT
# Call after `make <defconfig>` on a reused OUT (update/partial/kernel).
ga_pkg_inputs_rebuild_if_changed() {
  local _out="${1:?}" _ext="${2:?}" _root="${3:?}" _p _fp _rec _extra
  for _p in $GA_PKG_INPUT_PACKAGES; do
    _extra="$(ga_pkg_inputs_extra "$_out" "$_ext" "$_p")" || return 1
    if [[ "$_p" == fluent-bit && -z "$_extra" ]]; then
      echo "ERROR: pkg-inputs: could not read FLUENT_BIT_CONF_OPTS (make printvars failed)" >&2
      return 1
    fi
    _fp="$(ga_pkg_inputs_fingerprint "$_p" "$_root" "$_extra")"
    _rec="$(cat "$(ga_pkg_inputs_stamp "$_out" "$_p")" 2>/dev/null || true)"
    if [[ "$_rec" == "$_fp" ]]; then
      echo "pkg-inputs: $_p: patches and configure options unchanged since the last good build -- no rebuild"
      continue
    fi
    echo "WARNING: pkg-inputs: $_p: our patches/configure options changed (or were never recorded in this tree) -- dircleaning $_p so they are applied"
    rm -f "$(ga_pkg_inputs_stamp "$_out" "$_p")"
    make O="$_out" BR2_EXTERNAL="$_ext" "${_p}-dirclean" || return 1
  done
}

# ga_pkg_inputs_record OUT BR2_EXTERNAL_PATH PATCH_ROOT -- only after the build succeeded.
ga_pkg_inputs_record() {
  local _out="${1:?}" _ext="${2:?}" _root="${3:?}" _p _extra
  mkdir -p "$_out/.ga-pkg-inputs" || return 1
  for _p in $GA_PKG_INPUT_PACKAGES; do
    _extra="$(ga_pkg_inputs_extra "$_out" "$_ext" "$_p")" || return 1
    ga_pkg_inputs_fingerprint "$_p" "$_root" "$_extra" > "$(ga_pkg_inputs_stamp "$_out" "$_p")"
  done
}
