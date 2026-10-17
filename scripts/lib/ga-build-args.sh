# shellcheck shell=bash
# ga-build-args.sh — argument parsing for scripts/ga_build.sh, sourced.
#
# There is ONE build mode (ADR-0027 Amendment 1, D9). Every bake is signed with
# the one signing certificate under the one OTA root, requires a root password
# hash, and runs the SBOM, the CVE gate, the keyring audit and the build tests.
# The only choice left is how much of the tree to rebuild:
#
#   ga_build.sh [--board <board>] [full|partial|kernel|update]
#                                                 (default: --board ihost full)
#
# The board names one entry of scripts/lib/tree-paths.sh (GA_BOARDS); its board
# dir and defconfig come from there. A board the map does not define is refused.
#
# Kept in its own file so the parser can be exercised without starting a
# build: tests/gates/build_mode/selftest.sh sources THIS file and drives the
# live function, and the ga-ops bake refuses to start on a tree whose parser
# does not refuse `dev`.
#
# Compatibility with callers written before D9:
#   prod  (positional or GA_ENV=prod) — accepted, IGNORED, with a loud
#         deprecation banner. Every bake since 2026-08-31 passed it, so refusing
#         it would break the release train on the day this lands for no gain:
#         what it asked for is exactly what every build now does.
#   dev / test (positional or GA_ENV=dev|test) — REFUSED. A caller asking for
#         a dev build expects the fast path without the gates and a different
#         key. Neither exists any more; building anyway would hand that caller
#         something other than what it asked for, silently.
#   any other GA_ENV value — refused, as before.
#
# On return: MODE and BOARD are set; GA_ENV is unset so that nothing further
# down the build can key a decision on it.

# shellcheck source=tree-paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/tree-paths.sh"

ga_build_usage() {
  echo "Usage: ga_build.sh [--board <board>] [full|partial|kernel|update]   (default: --board ihost full)"
  echo "       boards: ${GA_BOARDS}"
}

_ga_build_no_dev() {
  echo "ERROR: '$1' is not a build mode any more." >&2
  echo "       There is one build (ADR-0027 D9): signed with the production signing" >&2
  echo "       certificate, root password required, SBOM + CVE gate + keyring audit" >&2
  echo "       + build tests on every bake. Drop the argument:" >&2
  echo "         ga_build.sh [full|partial|kernel|update]" >&2
}

_ga_build_prod_deprecated() {
  echo "==========================================================================" >&2
  echo "DEPRECATED: $1 is ignored. There is one build mode (ADR-0027 D9);" >&2
  echo "            every bake is what 'prod' used to mean. Remove it from the" >&2
  echo "            caller — a future version will refuse it." >&2
  echo "==========================================================================" >&2
}

# ga_parse_build_args "$@" — sets MODE and BOARD, validates and unsets GA_ENV.
# Returns non-zero (never exits) so a caller that sources this can decide.
ga_parse_build_args() {
  MODE=""
  BOARD=""
  local arg
  while [[ $# -gt 0 ]]; do
    arg="$1"; shift
    case "$arg" in
      --board|--board=*)
        if [[ -n "$BOARD" ]]; then
          echo "ERROR: Duplicate --board (already have '$BOARD')." >&2
          return 1
        fi
        if [[ "$arg" == --board ]]; then
          [[ $# -gt 0 ]] || { echo "ERROR: --board needs a board name (${GA_BOARDS})." >&2; return 1; }
          BOARD="$1"; shift
        else
          BOARD="${arg#--board=}"
        fi
        if ! [[ " ${GA_BOARDS} " == *" ${BOARD} "* ]] || ! ga_board_var BOARD_DIR "$BOARD" >/dev/null; then
          echo "ERROR: Unknown board '${BOARD}' (scripts/lib/tree-paths.sh defines: ${GA_BOARDS})." >&2
          return 1
        fi
        ;;
      full|partial|kernel|update)
        if [[ -n "$MODE" ]]; then
          echo "ERROR: Duplicate mode argument: '$arg' (already have '$MODE')." >&2
          return 1
        fi
        MODE="$arg"
        ;;
      prod)
        _ga_build_prod_deprecated "the argument 'prod'"
        ;;
      dev|test)
        _ga_build_no_dev "$arg"
        return 1
        ;;
      *)
        echo "ERROR: Unknown argument '$arg'." >&2
        ga_build_usage >&2
        return 1
        ;;
    esac
  done

  case "${GA_ENV-}" in
    "") ;;
    prod) _ga_build_prod_deprecated "GA_ENV=prod" ;;
    dev|test)
      _ga_build_no_dev "GA_ENV=${GA_ENV}"
      return 1
      ;;
    *)
      echo "ERROR: GA_ENV='${GA_ENV}' is set. GA_ENV no longer selects anything at" >&2
      echo "       build time (ADR-0027 D9); unset it." >&2
      return 1
      ;;
  esac
  unset GA_ENV

  MODE="${MODE:-full}"
  BOARD="${BOARD:-ihost}"
  return 0
}
