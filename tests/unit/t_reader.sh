#!/usr/bin/env bash
# t_reader.sh -- registry-query.sh contract (DESIGN 4.1-4.4, invariants I13/I21 sh side):
# rows/shared/packages on tests/fixtures/registry-{mini,edge,bad} against the committed
# expected outputs (tests/fixtures/expected/registry-query/); strict = exit 1 + ERROR
# lines, --lenient = WARN lines + exit 0; without jq (nojq, jq15 shims) rows/shared/
# check-jq exit 2 + INSTALL_REQUIRED:jq while packages falls back to awk; registry
# resolution (--registry > SDK_REGISTRY_DIR > <script dir>/../registry); usage errors;
# the real registry; source rules (ASCII-only .ps1, no regex in the jq program,
# function-only registry-lib.ps1). Product scripts run with $BASH32 when set.
# requires: NS/registry-query.sh NS/registry-query.jq
# requires: cmd: have_jq16
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
export LC_ALL=C

RQ=$NS/registry-query.sh
FIX=$TESTS_DIR/fixtures
EXP=$FIX/expected/registry-query
mktemp_dir tmp
TAB=$(printf '\t')

rq() { # rq <name> <args...>: run registry-query, keep stdout/stderr/rc in $tmp/<name>.*
  _n=$1; shift
  run_bash "$RQ" "$@" >"$tmp/$_n.out" 2>"$tmp/$_n.err"
  echo $? >"$tmp/$_n.rc"
}
rc_of() { cat "$tmp/$1.rc"; }

# ---- fixtures vs expected -------------------------------------------------------------
for v in rows packages shared; do
  rq "mini.$v" --registry "$FIX/registry-mini" "$v"
  assert_eq 0 "$(rc_of "mini.$v")" "mini $v: exit 0"
  assert_files_eq "$EXP/mini.$v.tsv" "$tmp/mini.$v.out" "mini $v: output == expected"
  assert_eq "" "$(cat "$tmp/mini.$v.err")" "mini $v: nothing on stderr"
done
rq mini.rows.len --registry "$FIX/registry-mini" rows --lenient
assert_files_eq "$EXP/mini.rows.tsv" "$tmp/mini.rows.len.out" "mini rows --lenient == strict on a clean registry"

for d in edge bad; do
  for v in rows packages; do
    rq "$d.$v.strict" --registry "$FIX/registry-$d" "$v"
    assert_eq 1 "$(rc_of "$d.$v.strict")" "$d $v strict: exit 1"
    assert_eq "" "$(cat "$tmp/$d.$v.strict.out")" "$d $v strict: no stdout"
    assert_files_eq "$EXP/$d.strict.err" "$tmp/$d.$v.strict.err" "$d $v strict: ERROR lines == expected"
    rq "$d.$v.len" --registry "$FIX/registry-$d" "$v" --lenient
    assert_eq 0 "$(rc_of "$d.$v.len")" "$d $v --lenient: exit 0"
    assert_files_eq "$EXP/$d.lenient.err" "$tmp/$d.$v.len.err" "$d $v --lenient: WARN lines == expected"
    assert_files_eq "$EXP/$d.lenient.$v.tsv" "$tmp/$d.$v.len.out" "$d $v --lenient: output == expected"
  done
done
# the messages the design names (4.3) are really exercised by the fixtures
for m in 'BOM not allowed' 'case-colliding keys: ' ; do
  assert_true "edge fixture covers '$m'" grep -q "$m" "$EXP/edge.strict.err"
done
for m in 'invalid JSON' 'more than one JSON document' 'empty file' 'root is not an object' \
         'sdk_id missing or not a string' 'targets is null' 'duplicate sdk_id'; do
  assert_true "bad fixture covers '$m'" grep -q "$m" "$EXP/bad.strict.err"
done
# the shared file is never skipped
rq edge.shared --registry "$FIX/registry-edge" shared
assert_eq 0 "$(rc_of edge.shared)" "shared ignores the entry files (BOM/case entries do not matter)"
mkdir -p "$tmp/sharedbom"
cp "$FIX/registry-mini/alpha.json" "$tmp/sharedbom/"
{ printf '\357\273\277'; cat "$FIX/registry-mini/_audit-shared.json"; } >"$tmp/sharedbom/_audit-shared.json"
rq sharedbom --registry "$tmp/sharedbom" rows --lenient
assert_eq 1 "$(rc_of sharedbom)" "a BOM in _audit-shared.json is fatal even with --lenient"
assert_eq "registry-query: ERROR _audit-shared.json: BOM not allowed" "$(cat "$tmp/sharedbom.err")" "shared BOM message"

# ---- no jq / jq 1.5 ---------------------------------------------------------------------
for shim in nojq jq15; do
  for v in rows shared check-jq; do
    with_shim "$shim" run_bash "$RQ" --registry "$FIX/registry-mini" "$v" >"$tmp/$shim.$v.out" 2>"$tmp/$shim.$v.err"
    assert_eq 2 "$?" "$shim: $v exits 2"
    assert_eq "INSTALL_REQUIRED:jq" "$(cat "$tmp/$shim.$v.out")" "$shim: $v prints INSTALL_REQUIRED:jq"
    assert_true "$shim: $v says how to install jq" grep -q 'Run: bash .*/skills/android-reverse-engineering/scripts/install-dep.sh jq$' "$tmp/$shim.$v.err"
  done
  with_shim "$shim" run_bash "$RQ" --registry "$FIX/registry-mini" packages >"$tmp/$shim.pk.out" 2>"$tmp/$shim.pk.err"
  assert_eq 0 "$?" "$shim: packages works (awk fallback)"
  assert_files_eq "$EXP/mini.packages.tsv" "$tmp/$shim.pk.out" "$shim: awk packages == expected"
  assert_eq "$(printf 'registry-query\t1\tawk')" "$(with_shim "$shim" run_bash "$RQ" version)" "$shim: version names the awk backend"
done
# awk fallback: the integrity problems it can see give the same messages as the jq path
mkdir -p "$tmp/awkbad"
for f in c-empty d-blank f-noid g-numid i-good j-dup k-good; do cp "$FIX/registry-bad/$f.json" "$tmp/awkbad/"; done
cp "$FIX/registry-edge/a-bom.json" "$tmp/awkbad/"
for m in "" --lenient; do
  rq "awkbad.jq$m" --registry "$tmp/awkbad" packages $m
  PATH="$TESTS_DIR/shims/nojq:$PATH" run_bash "$RQ" --registry "$tmp/awkbad" packages $m >"$tmp/awkbad.awk$m.out" 2>"$tmp/awkbad.awk$m.err"
  echo $? >"$tmp/awkbad.awk$m.rc"
  assert_eq "$(rc_of "awkbad.jq$m")" "$(rc_of "awkbad.awk$m")" "awk vs jq packages $m: same exit code"
  assert_files_eq "$tmp/awkbad.jq$m.err" "$tmp/awkbad.awk$m.err" "awk vs jq packages $m: same messages"
  assert_files_eq "$tmp/awkbad.jq$m.out" "$tmp/awkbad.awk$m.out" "awk vs jq packages $m: same output"
done

# ---- version / check-jq -------------------------------------------------------------------
rq version version
assert_eq 0 "$(rc_of version)" "version: exit 0"
assert_true "version: registry-query<TAB>1<TAB>jq-..." grep -q "^registry-query${TAB}1${TAB}jq-[0-9]" "$tmp/version.out"
rq checkjq check-jq
assert_eq 0 "$(rc_of checkjq)" "check-jq: exit 0 with jq >= 1.6"

# ---- registry resolution -------------------------------------------------------------------
SDK_REGISTRY_DIR="$FIX/registry-mini" run_bash "$RQ" rows >"$tmp/env.out" 2>&1
assert_files_eq "$EXP/mini.rows.tsv" "$tmp/env.out" "SDK_REGISTRY_DIR=... rows == --registry ... rows"
SDK_REGISTRY_DIR="$FIX/registry-bad" run_bash "$RQ" --registry "$FIX/registry-mini" rows >"$tmp/prec.out" 2>&1
assert_files_eq "$EXP/mini.rows.tsv" "$tmp/prec.out" "--registry wins over SDK_REGISTRY_DIR"
run_bash "$RQ" "--registry=$FIX/registry-mini" rows >"$tmp/eq.out" 2>&1
assert_files_eq "$EXP/mini.rows.tsv" "$tmp/eq.out" "--registry=DIR form"
run_bash "$RQ" rows --registry "$FIX/registry-mini/" >"$tmp/slash.out" 2>&1
assert_files_eq "$EXP/mini.rows.tsv" "$tmp/slash.out" "options after the verb, trailing slash"
(unset SDK_REGISTRY_DIR; run_bash "$RQ" rows) >"$tmp/def.out" 2>&1
run_bash "$RQ" --registry "$REG" rows >"$tmp/reg.out" 2>&1
assert_files_eq "$tmp/reg.out" "$tmp/def.out" "default registry = <script dir>/../registry"

# ---- usage and directory errors ----------------------------------------------------------
for args in "" "bogus" "--bogus rows" "--registry" "rows packages" "ROWS"; do
  # shellcheck disable=SC2086
  run_bash "$RQ" $args >/dev/null 2>"$tmp/usage.err"
  assert_eq 1 "$?" "usage error [$args]: exit 1"
  assert_true "usage error [$args]: message on stderr" grep -q '^registry-query: ' "$tmp/usage.err"
done
run_bash "$RQ" --help >"$tmp/help.out" 2>&1
assert_eq 0 "$?" "--help: exit 0"
assert_true "--help prints the usage" grep -q 'registry-query.sh \[--registry DIR\] rows' "$tmp/help.out"
rq missing --registry "$tmp/does-not-exist" rows
assert_eq 1 "$(rc_of missing)" "missing directory: exit 1"
assert_eq "registry-query: ERROR registry directory not found: $tmp/does-not-exist" "$(cat "$tmp/missing.err")" "missing directory: message"
mkdir -p "$tmp/empty"
cp "$FIX/registry-mini/_audit-shared.json" "$tmp/empty/"
for v in rows packages; do
  rq "empty.$v" --registry "$tmp/empty" "$v" --lenient
  assert_eq 1 "$(rc_of "empty.$v")" "no entry files ($v): exit 1"
  assert_eq "registry-query: ERROR no registry entries in $tmp/empty" "$(cat "$tmp/empty.$v.err")" "no entry files ($v): message"
done
mkdir -p "$tmp/noshared"
cp "$FIX/registry-mini/alpha.json" "$tmp/noshared/"
rq noshared --registry "$tmp/noshared" rows
assert_eq 1 "$(rc_of noshared)" "rows without _audit-shared.json: exit 1"
assert_eq "registry-query: ERROR _audit-shared.json: file not found in $tmp/noshared" "$(cat "$tmp/noshared.err")" "rows without _audit-shared.json: message"
rq noshared.pk --registry "$tmp/noshared" packages
assert_eq 0 "$(rc_of noshared.pk)" "packages does not need _audit-shared.json"
mkdir -p "$tmp/allbad"
cp "$FIX/registry-mini/_audit-shared.json" "$FIX/registry-bad/c-empty.json" "$FIX/registry-bad/f-noid.json" "$tmp/allbad/"
rq allbad --registry "$tmp/allbad" rows --lenient
assert_eq 1 "$(rc_of allbad)" "--lenient with no valid entry: exit 1"
assert_eq "registry-query: ERROR no valid entries in $tmp/allbad" "$(tail -n 1 "$tmp/allbad.err")" "--lenient with no valid entry: message"

# ---- the real registry ------------------------------------------------------------------------
rq real.rows --registry "$REG" rows
assert_eq 0 "$(rc_of real.rows)" "real registry: rows exit 0"
assert_eq "" "$(cat "$tmp/real.rows.err")" "real registry: no warning"
n_files=$(ls "$REG"/*.json | awk -F/ '$NF !~ /^_/' | wc -l | tr -d ' ')
assert_eq "$n_files" "$(awk -F '\t' '$3 == "file"' "$tmp/real.rows.out" | wc -l | tr -d ' ')" "real registry: one file row per entry file"
assert_eq "$n_files" "$(awk -F '\t' '$3 == "group"' "$tmp/real.rows.out" | wc -l | tr -d ' ')" "real registry: one group row per entry"
awk -F '\t' '$3 == "file" { print $1 }' "$tmp/real.rows.out" >"$tmp/real.ids"
sort "$tmp/real.ids" >"$tmp/real.ids.sorted"
assert_files_eq "$tmp/real.ids.sorted" "$tmp/real.ids" "real registry: entries in ordinal sdk_id order"
assert_eq "consent-umptcf.json" "$(awk -F '\t' '$1 == "google-ump-consent" && $3 == "file" { print $4 }' "$tmp/real.rows.out")" "real registry: rows are keyed by sdk_id, not by file name (consent-umptcf.json)"
awk -F '\t' 'NF != 4 || $4 == ""' "$tmp/real.rows.out" >"$tmp/real.badrows"
assert_eq "" "$(head -n 3 "$tmp/real.badrows")" "real registry: every row has 4 non-empty cells"
rq real.pk --registry "$REG" packages
assert_eq "$(jq -r '.packages[]' "$REG"/[!_]*.json | wc -l | tr -d ' ')" "$(wc -l <"$tmp/real.pk.out" | tr -d ' ')" "real registry: one packages row per .packages[] item"
assert_eq "$(awk -F '\t' '$3 == "package"' "$tmp/real.rows.out" | cut -f1,4)" "$(cut -f1,3 "$tmp/real.pk.out")" "real registry: packages == the package rows of rows"
rq real.shared --registry "$REG" shared
assert_eq 0 "$(rc_of real.shared)" "real registry: shared exit 0"
assert_eq "$(printf 'section_separator\t-\t \342\200\224 ')" "$(grep '^section_separator' "$tmp/real.shared.out")" "shared: the em-dash separator comes from the UTF-8 data file"
assert_eq "category_group tool_group section_separator legacy_flag role_label format_token library_root hint_meta hint_title hint_token" \
  "$(cut -f1 "$tmp/real.shared.out" | awk '!s[$0]++' | tr '\n' ' ' | sed 's/ $//')" "shared: every kind, in file order"
assert_eq "" "$(grep -E '^legacy_flag.*(segment|flurry)' "$tmp/real.shared.out")" "legacy_flags without segment/flurry (they arrive with their entries, commit 7a)"

# ---- source rules --------------------------------------------------------------------------------
for f in "$NS/registry-query.sh" "$NS/registry-query.jq" "$NS/registry-lib.ps1" "$NS/registry-query.ps1"; do
  [ -f "$f" ] || continue
  assert_eq 0 "$(tr -d '\n' <"$f" | tr -cd '\r' | wc -c | tr -d ' ')" "$(basename "$f"): LF line endings"
done
for f in "$NS/registry-lib.ps1" "$NS/registry-query.ps1"; do
  [ -f "$f" ] || continue
  assert_eq "" "$(grep -n "$(printf '[\200-\377]')" "$f" | head -n 3)" "$(basename "$f"): ASCII-only"
done
if [ -f "$NS/registry-lib.ps1" ]; then
  # function-only library: at column 0 only comments, blank lines, `function` and `}`
  assert_eq "" "$(grep -nvE '^(#.*|[[:space:]].*|function [A-Za-z-]+ \{|\}|)$' "$NS/registry-lib.ps1" | head -n 3)" \
    "registry-lib.ps1 has no top-level statement (functions only)"
  assert_eq "" "$(grep -niE '^(param|set-strictmode|\$ErrorActionPreference|\[Console\])' "$NS/registry-lib.ps1")" \
    "registry-lib.ps1: no param() block / StrictMode / preference at top level"
fi
# jq 1.6 rules (DESIGN 4.3): no regex builtins, none of the newer builtins
code=$(sed 's/#.*//' "$NS/registry-query.jq")
for b in 'test(' 'match(' 'capture(' 'sub(' 'splits(' 'scan(' 'pick(' 'abs' 'trim' 'toarray' 'limit(0' 'debug' 'stderr' 'input_line_number'; do
  assert_eq "" "$(printf '%s\n' "$code" | grep -nF -- "$b" | head -n 2)" "registry-query.jq does not use $b"
done

echo "bash used for the product script: ${BASH32:-bash}"
t_done
