#!/usr/bin/env bash
# t_pkg_parity.sh -- T-PKG-PARITY (DESIGN 4.4, invariant I21): `registry-query.sh
# packages` through the POSIX awk fallback (no jq: tests/shims/nojq; old jq:
# tests/shims/jq15, whose >= 1.6 probe fails) is byte-identical to the jq path -- stdout,
# stderr and exit code -- on the real registry and on tests/fixtures/registry-mini (which
# has a one-line packages array, a "packages" key on its own line, and a description
# that contains \"packages\": [ ... ), strict and --lenient.
# run.sh runs this test once per awk shim (gawk --posix, mawk, busybox awk).
# awk-matrix
# requires: NS/registry-query.sh
# requires: cmd: have_jq16
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
export LC_ALL=C

RQ=$NS/registry-query.sh
mktemp_dir tmp
echo "awk: ${ARE_AWK_SHIM:-default awk ($(command -v awk))}"

n=0
for reg in "$REG" "$TESTS_DIR/fixtures/registry-mini"; do
  n=$((n + 1))
  for m in "" --lenient; do
    run_bash "$RQ" --registry "$reg" packages $m >"$tmp/jq.out" 2>"$tmp/jq.err"
    rc_jq=$?
    assert_eq 0 "$rc_jq" "jq path [$reg $m]: exit 0"
    [ -s "$tmp/jq.out" ] || fail_check "jq path [$reg $m]: empty output"
    for shim in nojq jq15; do
      with_shim "$shim" run_bash "$RQ" --registry "$reg" packages $m >"$tmp/$shim.out" 2>"$tmp/$shim.err"
      assert_eq "$rc_jq" "$?" "$shim [$reg $m]: same exit code as jq"
      assert_files_eq "$tmp/jq.out" "$tmp/$shim.out" "$shim [$reg $m]: awk output == jq output"
      assert_files_eq "$tmp/jq.err" "$tmp/$shim.err" "$shim [$reg $m]: same stderr"
    done
  done
done
# the fixture really exercises the awk traps
mini=$TESTS_DIR/fixtures/registry-mini
assert_true "mini has a one-line packages array" grep -q '^[[:space:]]*"packages": \[".*"\],$' "$mini/beta.json"
assert_true "mini has a description with \\\"packages\\\": [" grep -q '\\"packages\\": \[' "$mini/beta.json"
assert_true "mini has a packages key whose [ is on the next line" grep -q '^[[:space:]]*"packages":$' "$mini/delta.json"
assert_false "the description's fake package never shows up" grep -q 'com.fake.pkg' "$tmp/nojq.out"
t_done
