#!/usr/bin/env bash
# tests/run.sh -- dev-only test runner (not shipped with the plugin; DESIGN 9.2).
#
# Usage: tests/run.sh [quick|full|<suite>|<test>...] [--expect-pass <suite|test>...] [-v]
#   (no argument)  = quick
#   quick          lint + unit + parity (fixtures)                      ~1-2 min
#   full           quick + golden + snapshot + corpus + bash32 + perf   ~50 min
#   <suite>        lint | unit | golden | snapshot | parity | corpus | bash32 | perf
#   <test>         a single test by name, e.g. t_lint (any tests/<dir>/t_*.sh)
#   --expect-pass  every following name (suite or test) must PASS: a SKIP of it counts
#                  as FAIL (DESIGN 10 "Suite che devono PASSARE"); the names are also run.
#                  A suite that resolves to no test script at all also counts as FAIL
#                  (an empty suite is a hidden SKIP); without --expect-pass it is
#                  reported as `SKIP <suite> no tests found`
#   --awk-matrix   run every selected unit test once per awk shim (gawk --posix, mawk,
#                  busybox awk: tests/shims/awk-*); implied by `full`. Tests with an
#                  `# awk-matrix` header line always run that way. The shim goes first
#                  on PATH and its name is in $ARE_AWK_SHIM.
#   -v             print the full output of every test, not only of failures
#   (with `full`, tests see ARE_FULL=1: e.g. t_parity then adds its 8-app corpus part)
#
# One line per test: PASS / FAIL / SKIP / SKIP(requires), then a summary listing the
# SKIPs. Exit 0 when nothing failed, 1 otherwise, 2 on bad usage.
#
# Suite discovery: unit, parity = <dir>/t_*.sh; corpus = every corpus/*.sh (the DESIGN
# 9.2 names: groundtruth.sh, exclusions-superset.sh, marker-verify.sh, ...) except the
# helper prepare-pristine.sh and perf*.sh (suite perf); bash32 = bash32/*.sh plus any
# <dir>/bash32.sh (DESIGN 9.1 I18).
#
# Test protocol (tests/lib/common.sh): exit 0 = PASS, 77 = SKIP, other = FAIL.
# Preconditions: `# requires: <token>...` lines in the leading comment block of a test
# (every line up to the first one that does not start with `#`; same for `# awk-matrix`).
#   NS/x, S/x, PL/x, REG/x, TESTS/x   the file must exist (NS = sdk-neutralizer/scripts,
#                                     S = skills, PL = plugin root, REG = registry)
#   cmd: <shell command>              must succeed (rest of the line; evaluated with
#                                     tests/lib/common.sh loaded, so helpers such as
#                                     have_jq16 / have_ps are available)
# An unmet requirement prints SKIP(requires): the feature is not there yet.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/common.sh"

usage() { sed -n '2,38p' "$0"; }

# suite -> test scripts (relative to tests/)
suite_tests() {
  case "$1" in
    lint)     echo lint/lint-registry.sh ;;
    unit)     ls "$TESTS_DIR"/unit/t_*.sh 2>/dev/null | sed "s#^$TESTS_DIR/##" ;;
    golden)   echo golden/t_golden.sh ;;
    snapshot) echo golden/t_snapshot.sh ;;
    parity)   ls "$TESTS_DIR"/parity/t_*.sh 2>/dev/null | sed "s#^$TESTS_DIR/##" ;;
    corpus)   ls "$TESTS_DIR"/corpus/*.sh 2>/dev/null | sed "s#^$TESTS_DIR/##" |
                grep -v -e '^corpus/prepare-pristine\.sh$' -e '^corpus/perf[^/]*\.sh$' ;;
    bash32)   ls "$TESTS_DIR"/bash32/*.sh "$TESTS_DIR"/*/bash32.sh 2>/dev/null |
                sed "s#^$TESTS_DIR/##" | awk '!seen[$0]++' ;;
    perf)     ls "$TESTS_DIR"/corpus/perf*.sh 2>/dev/null | sed "s#^$TESTS_DIR/##" ;;
    quick)    for s in lint unit parity; do suite_tests "$s"; done ;;
    full)     for s in lint unit parity golden snapshot corpus bash32 perf; do suite_tests "$s"; done ;;
    *)        return 1 ;;
  esac
}
is_suite() { case "$1" in lint|unit|golden|snapshot|parity|corpus|bash32|perf|quick|full) return 0 ;; esac; return 1; }
component_suites() { # quick/full -> their suites; a plain suite -> itself
  case "$1" in
    quick) echo lint unit parity ;;
    full)  echo lint unit parity golden snapshot corpus bash32 perf ;;
    *)     echo "$1" ;;
  esac
}
test_path() { # test name -> path relative to tests/ (empty if unknown)
  _n=${1%.sh}
  for _p in "$TESTS_DIR"/*/"$_n".sh; do [ -f "$_p" ] && { echo "${_p#$TESTS_DIR/}"; return 0; }; done
  return 1
}
test_name() { _b=$(basename "$1"); echo "${_b%.sh}"; }

# ---- arguments -----------------------------------------------------------------------
run_list=""      # test paths, in order, unique
expect_list=""   # test paths that must PASS
empty_run=""     # suites (named, or inside quick/full) with no test script
empty_expect=""  # ... of which named under --expect-pass
verbose=0
awk_matrix=0
mode=run
add_unique() { # add_unique <varname> <item>
  eval "_cur=\${$1}"
  case " $_cur " in *" $2 "*) ;; *) eval "$1=\"\${$1} \$2\"" ;; esac
}
resolve_names() { # resolve_names <name> -> test paths on stdout
  if is_suite "$1"; then suite_tests "$1"; return 0; fi
  test_path "$1"
}
note_empty() { # note_empty <name> <expected 0|1>: record the component suites of <name> with no test
  is_suite "$1" || return 0
  for _s in $(component_suites "$1"); do
    [ -n "$(suite_tests "$_s")" ] && continue
    add_unique empty_run "$_s"
    [ "$2" = 1 ] && add_unique empty_expect "$_s"
  done
  return 0
}
check_name() { # exit 2 on an unknown name (checked outside $(...), which would only exit a subshell)
  is_suite "$1" || test_path "$1" >/dev/null || { echo "run.sh: unknown suite or test: $1" >&2; exit 2; }
}
names_seen=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -v|--verbose) verbose=1 ;;
    --awk-matrix) awk_matrix=1 ;;
    --expect-pass) mode=expect ;;
    --expect-pass=*) for n in $(echo "${1#--expect-pass=}" | tr ',' ' '); do
                       check_name "$n"
                       note_empty "$n" 1
                       for t in $(resolve_names "$n"); do add_unique expect_list "$t"; add_unique run_list "$t"; done
                     done ;;
    -*) echo "run.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
    *) names_seen=1
       check_name "$1"
       [ "$1" = full ] && { awk_matrix=1; ARE_FULL=1; export ARE_FULL; }
       if [ "$mode" = expect ]; then note_empty "$1" 1; else note_empty "$1" 0; fi
       for t in $(resolve_names "$1"); do
         add_unique run_list "$t"
         [ "$mode" = expect ] && add_unique expect_list "$t"
       done ;;
  esac
  shift
done
if [ "$names_seen" = 0 ] && [ -z "$run_list" ]; then
  note_empty quick 0
  for t in $(suite_tests quick); do add_unique run_list "$t"; done
fi

# ---- run -----------------------------------------------------------------------------
mktemp_dir logs
n_pass=0; n_fail=0; n_skip=0
skips=""
fails=""
start_all=$(date +%s)
for s_ in $empty_run; do
  case " $empty_expect " in
    *" $s_ "*) n_fail=$((n_fail + 1)); fails="$fails $s_"
               printf 'FAIL  %-22s no tests found (not allowed by --expect-pass)\n' "$s_" ;;
    *)         n_skip=$((n_skip + 1)); skips="$skips $s_"
               printf 'SKIP  %-22s no tests found\n' "$s_" ;;
  esac
done
for t in $run_list; do
  name=$(test_name "$t")
  expected=0; case " $expect_list " in *" $t "*) expected=1 ;; esac
  unmet=$(requires_unmet "$TESTS_DIR/$t")
  if [ -n "$unmet" ]; then
    if [ "$expected" = 1 ]; then
      n_fail=$((n_fail + 1)); fails="$fails $name"
      printf 'FAIL  %-22s SKIP(requires) not allowed by --expect-pass: missing %s\n' "$name" "$unmet"
    else
      n_skip=$((n_skip + 1)); skips="$skips $name"
      printf 'SKIP(requires) %-14s missing %s\n' "$name" "$unmet"
    fi
    continue
  fi
  # awk matrix: tests with an `# awk-matrix` header line (and, with --awk-matrix / full,
  # every unit test) run once per available awk shim (DESIGN 4.4, risk 6)
  variants=-
  if header_block "$TESTS_DIR/$t" | grep -q '^# awk-matrix' ||
     { [ "$awk_matrix" = 1 ] && case "$t" in unit/*) true ;; *) false ;; esac; }; then
    variants=$(awk_shims | tr '\n' ' ')
    [ -n "$variants" ] || variants=-
  fi
  base_name=$name
  for v in $variants; do
    if [ "$v" = - ]; then name=$base_name; else name="$base_name[$v]"; fi
    log=$logs/$(echo "$name" | tr '[]' '__').log
    t0=$(date +%s)
    if [ "$v" = - ]; then
      bash "$TESTS_DIR/$t" >"$log" 2>&1
    else
      PATH="$TESTS_DIR/shims/$v:$PATH" ARE_AWK_SHIM=$v bash "$TESTS_DIR/$t" >"$log" 2>&1
    fi
    rc=$?
    dt=$(( $(date +%s) - t0 ))
    last=$(grep -v '^[[:space:]]*$' "$log" | tail -n 1)
    if [ "$rc" = 0 ]; then
      n_pass=$((n_pass + 1)); printf 'PASS  %-22s (%ss) %s\n' "$name" "$dt" "$last"
      [ "$verbose" = 1 ] && sed 's/^/      | /' "$log"
    elif [ "$rc" = "$SKIP_RC" ]; then
      if [ "$expected" = 1 ]; then
        n_fail=$((n_fail + 1)); fails="$fails $name"
        printf 'FAIL  %-22s SKIP not allowed by --expect-pass: %s\n' "$name" "$last"
      else
        n_skip=$((n_skip + 1)); skips="$skips $name"
        printf 'SKIP  %-22s %s\n' "$name" "$last"
      fi
      [ "$verbose" = 1 ] && sed 's/^/      | /' "$log"
    else
      n_fail=$((n_fail + 1)); fails="$fails $name"
      printf 'FAIL  %-22s (%ss, exit %s)\n' "$name" "$dt" "$rc"
      if [ "$verbose" = 1 ]; then sed 's/^/      | /' "$log"; else tail -n 60 "$log" | sed 's/^/      | /'; fi
    fi
  done
done

total=$((n_pass + n_fail + n_skip))
echo "----"
echo "run.sh: $total test(s): $n_pass passed, $n_fail failed, $n_skip skipped ($(( $(date +%s) - start_all ))s)"
[ -z "$skips" ] || echo "skipped:$skips"
[ -z "$fails" ] || echo "failed:$fails"
[ "$total" -gt 0 ] || { echo "run.sh: no tests selected" >&2; exit 1; }
[ "$n_fail" -eq 0 ]
