#!/usr/bin/env bash
# t_runner.sh -- tests/run.sh semantics on a throw-away copy of the harness (DESIGN 9.2,
# 10 "Suite che devono PASSARE"): --expect-pass turns SKIP, SKIP(requires) and an empty
# suite into FAIL; corpus/bash32 discovery follows the DESIGN 9.2 script names.
# Directives (`# requires:`, `# awk-matrix`) are honoured anywhere in the leading comment
# block (also past line 20) and every real test keeps them there (none further down,
# where they would be silently ignored).
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

mktemp_dir tmp
fk=$tmp/tests
mkdir -p "$fk/lib" "$fk/lint" "$fk/unit" "$fk/golden" "$fk/corpus"
cp "$TESTS_DIR/run.sh" "$fk/run.sh"
cp "$TESTS_DIR/lib/common.sh" "$fk/lib/common.sh"
mk() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$fk/$1"; }
mk lint/lint-registry.sh 'echo lint-ok'
mk unit/t_ok.sh 'echo unit-ok'
mk unit/t_skip.sh 'echo "SKIP: no tool"; exit 77'
mk golden/t_golden.sh 'echo golden-ok'
mk golden/t_snapshot.sh '# requires: TESTS/does-not-exist
echo never'
run() { ARE_PS=none bash "$fk/run.sh" "$@" >"$tmp/out" 2>&1; echo $?; }
has() { grep -q -- "$1" "$tmp/out"; }

# empty suites: SKIP normally, FAIL under --expect-pass (both argument forms)
assert_eq 0 "$(run parity t_ok)" "empty suite without --expect-pass: rc 0"
assert_true "empty suite reported as SKIP" has '^SKIP  parity  *no tests found'
assert_eq 1 "$(run --expect-pass parity t_ok)" "--expect-pass <empty suite>: rc 1"
assert_true "empty suite reported as FAIL" has '^FAIL  parity  *no tests found (not allowed by --expect-pass)'
assert_eq 1 "$(run --expect-pass=corpus,t_ok)" "--expect-pass=<empty suite>: rc 1"
assert_eq 1 "$(run t_ok --expect-pass full)" "--expect-pass full with empty component suites: rc 1"
assert_true "full: every empty component suite listed" has '^failed:.*parity.*corpus.*bash32.*perf'
assert_eq 0 "$(run)" "default quick with an empty parity suite: rc 0"
assert_true "quick lists the empty parity suite" has '^skipped:.* parity'

# SKIP and SKIP(requires) of expected tests are FAIL
assert_eq 0 "$(run unit)" "SKIP without --expect-pass: rc 0"
assert_eq 1 "$(run --expect-pass unit)" "SKIP under --expect-pass: rc 1"
assert_eq 0 "$(run snapshot)" "SKIP(requires) without --expect-pass: rc 0"
assert_eq 1 "$(run --expect-pass snapshot)" "SKIP(requires) under --expect-pass: rc 1"
assert_eq 0 "$(run --expect-pass lint golden t_ok)" "all expected PASS: rc 0"

# corpus discovery uses the DESIGN names and leaves helpers/perf out
mk corpus/groundtruth.sh 'echo gt-ok'
mk corpus/exclusions-superset.sh 'echo excl-ok'
mk corpus/marker-verify.sh 'echo marker-ok'
mk corpus/prepare-pristine.sh 'exit 1'
mk corpus/perf.sh 'echo perf-ok'
assert_eq 0 "$(run --expect-pass corpus)" "corpus with design-named scripts: rc 0"
assert_true "corpus runs groundtruth" has '^PASS  groundtruth '
assert_true "corpus runs exclusions-superset" has '^PASS  exclusions-superset '
assert_true "corpus runs marker-verify" has '^PASS  marker-verify '
assert_false "corpus does not run prepare-pristine" has 'prepare-pristine'
assert_false "corpus does not run perf" has 'perf'
assert_eq 0 "$(run --expect-pass perf)" "perf suite finds corpus/perf.sh"
assert_eq 0 "$(run --expect-pass marker-verify)" "a corpus script by name"
mk unit/bash32.sh 'echo b32-ok'
assert_eq 0 "$(run --expect-pass bash32)" "bash32 suite finds <dir>/bash32.sh"
assert_eq 2 "$(run nosuch)" "unknown suite or test name: rc 2"

# directives deep in a long header block are honoured; after the block they are not
hdr=$(i=0; while [ $i -lt 30 ]; do echo "# filler header line $i"; i=$((i + 1)); done)
printf '#!/usr/bin/env bash\n%s\n# requires: TESTS/does-not-exist\nexit 1\n' "$hdr" >"$fk/unit/t_deepreq.sh"
assert_eq 0 "$(run t_deepreq)" "# requires: on line 32 of the header is honoured: rc 0"
assert_true "deep # requires: prints SKIP(requires)" has '^SKIP(requires) t_deepreq '
mkdir -p "$fk/shims/awk-gawk-posix" "$fk/shims/awk-mawk" "$fk/shims/awk-busybox"
printf '#!/usr/bin/env bash\n%s\n# awk-matrix\necho "shim=${ARE_AWK_SHIM:-none}"\n' "$hdr" >"$fk/unit/t_deepawk.sh"
n_shims=$(awk_shims | wc -l | tr -d ' ')
if [ "$n_shims" -gt 0 ]; then
  assert_eq 0 "$(run t_deepawk)" "# awk-matrix on line 32 of the header: rc 0"
  assert_eq "$n_shims" "$(grep -c '^PASS  t_deepawk\[awk-' "$tmp/out")" "deep # awk-matrix runs once per awk shim"
fi
printf '#!/usr/bin/env bash\n# short header\nset -u\n# requires: TESTS/does-not-exist\necho body\n' >"$fk/unit/t_bodyreq.sh"
assert_eq 0 "$(run t_bodyreq)" "# requires: after the header block is not a directive: rc 0"
assert_true "body # requires: is ignored (PASS)" has '^PASS  t_bodyreq '
assert_eq "$fk/unit/t_bodyreq.sh:4: # requires: TESTS/does-not-exist" \
  "$(directives_outside_header "$fk/unit/t_bodyreq.sh")" "directives_outside_header flags it"

# lint of the real tree: no test keeps a directive where run.sh would not read it
stray=$(directives_outside_header "$TESTS_DIR"/*/*.sh "$TESTS_DIR"/run.sh)
assert_eq "" "$stray" "no # requires: / # awk-matrix line outside a leading comment block"
t_done
