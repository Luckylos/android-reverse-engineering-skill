#!/usr/bin/env bash
# t_shims.sh -- the harness shims behave as the suites expect (DESIGN 9.2).
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

with_shim nojq jq -n 1 >/dev/null 2>&1
assert_eq 127 "$?" "nojq: jq exits 127"
with_shim nosudo sudo true >/dev/null 2>&1
assert_eq 1 "$?" "nosudo: sudo always fails"
if command -v jq >/dev/null 2>&1; then
  assert_eq jq-1.5 "$(with_shim jq15 jq --version)" "jq15: --version says jq-1.5"
  with_shim jq15 jq -nr '[limit(1;1,2)] | IN(.[]; 1) | tostring' >/dev/null 2>&1
  assert_eq 3 "$?" "jq15: the >= 1.6 probe fails to compile"
  printf '[limit(1;1,2)]\n' >"${TMPDIR:-/tmp}/are-jq15-$$.jq"
  with_shim jq15 jq -n -f "${TMPDIR:-/tmp}/are-jq15-$$.jq" >/dev/null 2>&1
  assert_eq 3 "$?" "jq15: a -f program using limit fails too"
  rm -f "${TMPDIR:-/tmp}/are-jq15-$$.jq"
  assert_eq 3 "$(with_shim jq15 jq -n '1 + 2')" "jq15: other programs run on the real jq"
  assert_true "have_jq16 is false under jq15" sh -c '! PATH="$1:$PATH" jq -nr "[limit(1;1,2)] | IN(.[]; 1) | tostring" >/dev/null 2>&1' _ "$TESTS_DIR/shims/jq15"
fi
n=0
for s in $(awk_shims); do
  n=$((n + 1))
  assert_eq "a/b" "$(printf 'a.b\n' | with_shim "$s" awk '{ gsub(/\./, "/"); print }')" "$s: runs a POSIX awk program"
done
[ "$n" -gt 0 ] || skip "no awk shim available (gawk, mawk, busybox)"
echo "awk shims available: $(awk_shims | tr '\n' ' ')"
t_done
