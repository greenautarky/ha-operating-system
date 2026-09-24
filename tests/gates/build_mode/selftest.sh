#!/usr/bin/env bash
# =============================================================================
# selftest.sh — one build mode (ADR-0027 D9): `dev` must be refused, the real
# modes must keep working, and a leftover `prod` must be loud but harmless.
# =============================================================================
# Drives the LIVE parser (scripts/lib/ga-build-args.sh) — the same file
# ga_build.sh sources, and the same file the ga-ops bake asks before it starts
# a build. It also asserts that ga_build.sh really does source it and has no
# parser of its own, because a tested library that the build does not call is
# decoration.
#
# must-fail: every way of asking for the retired dev build, plus the argument
#            errors that were refused before.
# must-pass: every real mode, the default, and the deprecated `prod` spellings
#            (accept-and-ignore, with the banner — asserted, not assumed).
#
# Offline, no build, well under a second.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
LIB="$ROOT/scripts/lib/ga-build-args.sh"
BUILD="$ROOT/scripts/ga_build.sh"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=''; GRN=''; NC=''; }
fails=0; ran=0
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$NC" "$*"; fails=$((fails + 1)); }
ok()  { printf '  %sok%s    %s\n' "$GRN" "$NC" "$*"; }

[[ -r "$LIB"   ]] || { echo "FATAL: $LIB missing"; exit 1; }
[[ -r "$BUILD" ]] || { echo "FATAL: $BUILD missing"; exit 1; }

# One parse in a clean subshell. Prints "rc=<n> mode=<m> ga_env=<set|unset>"
# on stdout; stderr goes to $ERR.
ERR="$(mktemp)"; trap 'rm -f "$ERR"' EXIT
parse() { # parse <GA_ENV value or -> <args...>
  local env="$1"; shift
  (
    unset GA_ENV MODE
    [[ "$env" != "-" ]] && export GA_ENV="$env"
    # shellcheck source=../../../scripts/lib/ga-build-args.sh
    . "$LIB"
    ga_parse_build_args "$@"; rc=$?
    printf 'rc=%s mode=%s ga_env=%s\n' "$rc" "${MODE:-}" "${GA_ENV+set}"
  ) 2>"$ERR"
}

must_fail() { # must_fail <label> <stderr-regex> <GA_ENV|-> <args...>
  local label="$1" re="$2"; shift 2
  ran=$((ran + 1))
  local out; out="$(parse "$@")"
  if [[ "$out" == rc=0* ]]; then bad "$label — ACCEPTED ($out)"; return; fi
  if ! grep -qE -- "$re" "$ERR"; then bad "$label — refused, but not with the expected message ($re): $(head -1 "$ERR")"; return; fi
  ok "$label"
}
must_pass() { # must_pass <label> <want-mode> <banner:yes|no> <GA_ENV|-> <args...>
  local label="$1" want="$2" banner="$3"; shift 3
  ran=$((ran + 1))
  local out; out="$(parse "$@")"
  if [[ "$out" != "rc=0 mode=$want ga_env=" ]]; then bad "$label — got '$out', want 'rc=0 mode=$want ga_env=' (GA_ENV must be unset after parsing)"; return; fi
  if [[ "$banner" == yes ]] && ! grep -q 'DEPRECATED' "$ERR"; then bad "$label — accepted SILENTLY; a leftover 'prod' must print the deprecation banner"; return; fi
  if [[ "$banner" == no ]] && [[ -s "$ERR" ]]; then bad "$label — unexpected stderr: $(head -1 "$ERR")"; return; fi
  ok "$label"
}

echo "=== Gate self-test: one build mode (ADR-0027 D9) ==="
echo "parser read from ${LIB#"$ROOT"/} — not copied"
echo

echo "wiring — ga_build.sh must use THIS parser and no other:"
ran=$((ran + 1))
_code="$(sed 's/#.*//' "$BUILD")"
if grep -qE '^[[:space:]]*\.[[:space:]]+"\$\{SCRIPT_DIR\}/lib/ga-build-args\.sh"' <<<"$_code" \
   && grep -qE '^[[:space:]]*ga_parse_build_args "\$@"' <<<"$_code"; then
  ok "ga_build.sh sources lib/ga-build-args.sh and calls ga_parse_build_args \"\$@\""
else
  bad "ga_build.sh does not source lib/ga-build-args.sh and call ga_parse_build_args — the tested parser is not the one the build runs"
fi
ran=$((ran + 1))
if grep -qE '^[[:space:]]*(dev\|test\|prod|dev\|prod|dev\|test)\)' <<<"$_code" \
   || grep -qE 'GA_ENV:-dev|GA_ENV" == "prod"|GA_ENV == prod' <<<"$_code"; then
  bad "ga_build.sh still carries its own dev/prod handling"
else
  ok "ga_build.sh has no dev/prod case of its own and no GA_ENV branch"
fi
echo

echo "must-fail — the retired dev build, however it is asked for:"
must_fail "positional 'dev'"                 "not a build mode"  -     dev
must_fail "positional 'test'"                "not a build mode"  -     test
must_fail "'full dev'"                       "not a build mode"  -     full dev
must_fail "'dev update'"                     "not a build mode"  -     dev update
must_fail "GA_ENV=dev"                       "not a build mode"  dev
must_fail "GA_ENV=test with 'update'"        "not a build mode"  test  update
must_fail "GA_ENV=production (never valid)"  "no longer selects" production full
must_fail "unknown argument"                 "Unknown argument"  -     fast
must_fail "duplicate mode"                   "Duplicate mode"    -     full update
echo

echo "must-pass — every real mode keeps working:"
must_pass "no argument -> full"              full    no  -
must_pass "'full'"                           full    no  -     full
must_pass "'partial'"                        partial no  -     partial
must_pass "'kernel'"                         kernel  no  -     kernel
must_pass "'update'"                         update  no  -     update
must_pass "'update prod' (ga-ops before D9)" update  yes -     update prod
must_pass "'prod' alone"                     full    yes -     prod
must_pass "GA_ENV=prod with 'update'"        update  yes prod  update
echo

if (( ran < 19 )); then
  echo "ERROR: only $ran checks ran — refusing to report a pass over a shrunken set" >&2
  exit 2
fi
echo "${ran} checks, ${fails} failed"
(( fails == 0 )) || exit 1
echo "dev is refused in every spelling; every real mode and the deprecated prod spelling still build."
