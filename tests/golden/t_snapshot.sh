#!/usr/bin/env bash
# t_snapshot.sh -- T-SNAPSHOT (invariants I2, I3; rules R1, R2 of DESIGN 3.1).
# The consumed projection (tests/golden/snapshot.sh) of each entry of
# snapshot.before.jsonl (48 at 4c166fe; rebaselined on intended neutralization changes, see
# tests/README.md "Intended neutralization changes") must be byte-identical today: same file, same order, same
# sdk_id / display_name / category / packages (order included) / targets /
# manifest_components / protected_patterns / in_house_wrapper. Entries added later
# (detection-only, DESIGN 3.3) are allowed only without targets, manifest_components
# and protected_patterns.
# requires: cmd: have_jq16
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

BEFORE=$TESTS_DIR/golden/snapshot.before.jsonl
mktemp_dir tmp
bash "$TESTS_DIR/golden/snapshot.sh" "$REG" >"$tmp/now.jsonl" 2>"$tmp/err"
assert_eq 0 "$?" "snapshot.sh runs cleanly on $REG"
[ -s "$tmp/err" ] && sed 's/^/    /' "$tmp/err"

jq -r '.file' "$BEFORE" >"$tmp/before.files"
jq -r '.file' "$tmp/now.jsonl" >"$tmp/now.files"

# I2: every original file still present, relative order unchanged.
grep -Fxf "$tmp/before.files" "$tmp/now.files" >"$tmp/kept.files"
assert_files_eq "$tmp/before.files" "$tmp/kept.files" "I2: the baseline entry files are all present, in the same order"

# I3/R1: projection of every original entry unchanged.
grep -F -f <(sed 's/.*/"file":"&"/' "$tmp/before.files") "$tmp/now.jsonl" >"$tmp/now.kept.jsonl"
assert_files_eq "$BEFORE" "$tmp/now.kept.jsonl" "I3: consumed projection of the original entries is byte-identical"

# R2: new entries are detection-only.
grep -Fvxf "$tmp/before.files" "$tmp/now.files" >"$tmp/new.files" || true
while IFS= read -r nf; do
  [ -n "$nf" ] || continue
  line=$(grep -F "\"file\":\"$nf\"" "$tmp/now.jsonl")
  ok=$(printf '%s\n' "$line" | jq -r '(.has_targets | not) and (.manifest_classes == []) and (.protected_method_names == [])')
  assert_eq true "$ok" "R2: new entry $nf is detection-only (no targets / manifest_components / protected_patterns)"
done <"$tmp/new.files"
echo "snapshot: $(wc -l <"$tmp/before.files" | tr -d ' ') original entries, $(grep -c . "$tmp/new.files" || true) new"
t_done
