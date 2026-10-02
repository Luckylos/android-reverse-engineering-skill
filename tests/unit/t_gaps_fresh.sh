#!/usr/bin/env bash
# t_gaps_fresh.sh -- gaps-fresh (DESIGN 3.4, 7): the generated part of
# skills/sdk-neutralizer/references/registry-backlog.md (between the registry-gaps
# markers) equals what tests/tools/registry-gaps.sh computes from the registry under
# test, so the backlog cannot drift from the registry.
# Also checks the tool itself on throw-away copies: a registry change makes --check fail
# (rc 1), --write repairs the block and leaves the hand-written text untouched, missing
# markers give rc 2, and the output does not depend on the awk/jq run (deterministic).
# requires: TESTS/tools/registry-gaps.sh REG/_audit-shared.json
# requires: S/sdk-neutralizer/references/registry-backlog.md
# requires: cmd: have_jq16
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
export LC_ALL=C

GAPS=$TESTS_DIR/tools/registry-gaps.sh
BACKLOG=$S/sdk-neutralizer/references/registry-backlog.md

# 1. the committed backlog is fresh
out=$(bash "$GAPS" --check --registry "$REG" --file "$BACKLOG" 2>&1); rc=$?
assert_eq 0 "$rc" "registry-backlog.md is up to date (bash tests/tools/registry-gaps.sh --write to refresh)"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | head -40 | sed 's/^/    /'

# 2. deterministic: two runs give the same bytes
mktemp_dir tmp
bash "$GAPS" --registry "$REG" >"$tmp/a" 2>&1
bash "$GAPS" --registry "$REG" >"$tmp/b" 2>&1
assert_files_eq "$tmp/a" "$tmp/b" "two runs give identical output"
assert_true "block starts with the BEGIN marker" grep -q '^<!-- BEGIN registry-gaps' "$tmp/a"
assert_true "every detection-only entry has a DO row" sh -c '
  n=$(grep -c "| DO |" "$1"); m=$(for f in "$2"/[!_]*.json; do jq -e "has(\"targets\") | not" "$f" >/dev/null && echo x; done | wc -l)
  [ "$n" -eq "$m" ] && [ "$n" -gt 0 ]' _ "$tmp/a" "$REG"

# 3. a registry change makes the backlog stale; --write repairs only the block
cp -R "$REG" "$tmp/reg"
cp "$BACKLOG" "$tmp/backlog.md"
jq '.detection.extra_packages += ["sg.bigo.zz"]' "$tmp/reg/bigo-ads.json" >"$tmp/x.json" &&
  mv "$tmp/x.json" "$tmp/reg/bigo-ads.json"
bash "$GAPS" --check --registry "$tmp/reg" --file "$tmp/backlog.md" >"$tmp/check.out" 2>&1; rc=$?
assert_eq 1 "$rc" "--check on a changed registry: rc 1"
assert_true "--check names the new gap in its diff" grep -q 'sg.bigo.zz' "$tmp/check.out"
bash "$GAPS" --write --registry "$tmp/reg" --file "$tmp/backlog.md" >/dev/null 2>&1
assert_eq 0 "$?" "--write: rc 0"
bash "$GAPS" --check --registry "$tmp/reg" --file "$tmp/backlog.md" >/dev/null 2>&1
assert_eq 0 "$?" "--check after --write: rc 0"
b='<!-- BEGIN registry-gaps'; e='<!-- END registry-gaps -->'
outside() { awk -v b="$b" -v e="$e" 'index($0, b) == 1 { on = 1 } !on { print } $0 == e { on = 0 }' "$1"; }
outside "$BACKLOG" >"$tmp/o1"; outside "$tmp/backlog.md" >"$tmp/o2"
assert_files_eq "$tmp/o1" "$tmp/o2" "--write leaves the hand-written text untouched"

# 3b. coverage is "equal to or under a packages item": a root strictly under
#     sg.bigo.ads (packages of bigo-ads) is covered, a sibling with the same string
#     prefix (sg.bigo.adsx) is not
cp -R "$REG" "$tmp/reg2"
jq '.detection.extra_packages += ["sg.bigo.ads.zz", "sg.bigo.ads", "sg.bigo.adsx"]' \
  "$tmp/reg2/bigo-ads.json" >"$tmp/x.json" && mv "$tmp/x.json" "$tmp/reg2/bigo-ads.json"
bash "$GAPS" --registry "$tmp/reg2" >"$tmp/c" 2>&1
assert_true "a root strictly under a packages item gives no P item" \
  sh -c '! grep "| \`bigo-ads\` | P |" "$1" | grep -q "sg\.bigo\.ads\.zz"' _ "$tmp/c"
assert_true "a root equal to a packages item gives no P item" \
  sh -c '! grep "| \`bigo-ads\` | P |" "$1" | grep -q "\`sg\.bigo\.ads\`"' _ "$tmp/c"
assert_true "a root sharing only a string prefix is a P item" \
  sh -c 'grep "| \`bigo-ads\` | P |" "$1" | grep -q "sg\.bigo\.adsx"' _ "$tmp/c"

# 4. missing markers: rc 2
grep -v 'registry-gaps' "$BACKLOG" >"$tmp/nomark.md"
bash "$GAPS" --check --registry "$REG" --file "$tmp/nomark.md" >/dev/null 2>&1
assert_eq 2 "$?" "--check without markers: rc 2"
bash "$GAPS" --check --registry "$REG" --file "$tmp/missing.md" >/dev/null 2>&1
assert_eq 2 "$?" "--check on a missing file: rc 2"

t_done
