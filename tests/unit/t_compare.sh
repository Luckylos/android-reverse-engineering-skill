#!/usr/bin/env bash
# t_compare.sh -- self-test of tests/golden/compare.sh on tiny fake captures: identical,
# changed, missing and extra files, and the per-part baselines (synth48 -> G-synth,
# adwrapper-noreg -> adwrapper, adwrapper-ps1* -> the ps1 baseline).
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

CMP=$TESTS_DIR/golden/compare.sh
mktemp_dir tmp
export ARE_GOLD=$tmp/gold
mk() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" >"$1"; }

A=$ARE_GOLD/before
mk "$A/scan/app/d1-all/stdout" "MATCHED:x"
mk "$A/scan/app/d1-all/exit" "0"
mk "$A/adwrapper/app/stdout" "ADWRAPPER_SUMMARY:none"
mk "$ARE_GOLD/adwrapper-ps1-before/app.norm" "ADWRAPPER_SUMMARY:none"
: >"$ARE_GOLD/adwrapper-ps1-before/app.stderr"
mk "$ARE_GOLD/adwrapper-ps1-before/app.stdout" "raw, never compared"

B=$tmp/after
cp -r "$A" "$B"
out=$(bash "$CMP" before "$B"); rc=$?
assert_eq 0 "$rc" "identical captures -> exit 0"
assert_true "prints IDENTICAL" sh -c 'printf "%s\n" "$1" | grep -q "^IDENTICAL: "' _ "$out"

mk "$B/adwrapper-noreg/app/stdout" "ADWRAPPER_SUMMARY:none"
mkdir -p "$B/adwrapper-ps1"
cp "$ARE_GOLD/adwrapper-ps1-before/app.norm" "$ARE_GOLD/adwrapper-ps1-before/app.stderr" "$B/adwrapper-ps1/"
cp -r "$TESTS_DIR/golden/synth48.before" "$B/synth48"
bash "$CMP" before "$B" >"$tmp/o" 2>&1; rc=$?
assert_eq 0 "$rc" "noreg / ps1 / synth48 parts compare against their own baselines"
[ "$rc" = 0 ] || head -20 "$tmp/o"

mk "$B/adwrapper-noreg/app/stdout" "ADWRAPPER_SUMMARY:candidate"
bash "$CMP" before "$B" >"$tmp/o" 2>&1; rc=$?
assert_eq 1 "$rc" "a changed noreg output is a difference"
assert_true "names the changed file" grep -q '^DIFF: adwrapper-noreg/app/stdout$' "$tmp/o"
mk "$B/adwrapper-noreg/app/stdout" "ADWRAPPER_SUMMARY:none"

printf 'changed\n' >>"$B/synth48/d2-ads/registry-targets.txt"
bash "$CMP" before "$B" >"$tmp/o" 2>&1; rc=$?
assert_eq 1 "$rc" "a changed synth48 file is a difference"
assert_true "names the synth48 file" grep -q '^DIFF: synth48/d2-ads/registry-targets.txt$' "$tmp/o"
cp "$TESTS_DIR/golden/synth48.before/d2-ads/registry-targets.txt" "$B/synth48/d2-ads/registry-targets.txt"

rm "$B/synth48/d3-all/exit"
bash "$CMP" before "$B" >"$tmp/o" 2>&1; rc=$?
assert_eq 1 "$rc" "a missing file is a difference"
assert_true "reports it missing" grep -q '^DIFF: synth48/d3-all/exit (missing in candidate)$' "$tmp/o"
cp "$TESTS_DIR/golden/synth48.before/d3-all/exit" "$B/synth48/d3-all/exit"

mk "$B/scan/app/d1-all/extra.txt" "x"
bash "$CMP" before "$B" >"$tmp/o" 2>&1; rc=$?
assert_eq 1 "$rc" "an extra file is a difference"
assert_true "reports it extra" grep -q '^DIFF: scan/app/d1-all/extra.txt (only in candidate)$' "$tmp/o"
rm "$B/scan/app/d1-all/extra.txt"

: >"$B/adwrapper-ps1/app.EXIT_1"
bash "$CMP" before "$B" >"$tmp/o" 2>&1; rc=$?
assert_eq 1 "$rc" "a ps1 non-zero exit marker is a difference"
rm "$B/adwrapper-ps1/app.EXIT_1"

bash "$CMP" before "$B" >"$tmp/o" 2>&1
assert_eq 0 "$?" "back to identical"
bash "$CMP" before >/dev/null 2>&1
assert_eq 2 "$?" "bad usage -> exit 2"
t_done
