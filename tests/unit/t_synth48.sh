#!/usr/bin/env bash
# t_synth48.sh -- tests/fixtures/make-synth48.sh is deterministic and complete for the
# registry of $ARE_BASE_COMMIT (the one G-synth was captured from): every package has a
# class, every target class declares every target method, every manifest component is
# declared, and registry-scan matches all 48 entries.
# requires: cmd: git -C "$REPO" cat-file -e "$ARE_BASE_COMMIT^{commit}"
# requires: cmd: have_jq16
# requires: cmd: command -v python3 >/dev/null
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
mktemp_dir tmp
git -C "$REPO" archive "$ARE_BASE_COMMIT" plugins/android-reverse-engineering/skills/sdk-neutralizer/registry | tar -x -C "$tmp" ||
  die "cannot extract the registry of $ARE_BASE_COMMIT"
R=$tmp/plugins/android-reverse-engineering/skills/sdk-neutralizer/registry
bash "$TESTS_DIR/fixtures/make-synth48.sh" "$R" "$tmp/a" 2>/dev/null
assert_eq 0 "$?" "make-synth48.sh runs"
bash "$TESTS_DIR/fixtures/make-synth48.sh" "$R" "$tmp/b" 2>/dev/null
assert_true "two runs give identical trees" diff -r "$tmp/a" "$tmp/b"

entries=$(ls "$R"/*.json | grep -v '/_' | wc -l | tr -d ' ')
assert_eq 48 "$entries" "the base registry has 48 entries"
missing=$(jq -r '.packages[]' "$R"/[!_]*.json | tr . / | while IFS= read -r p; do
  [ -d "$tmp/a/smali/$p" ] || echo "$p"; done)
assert_eq "" "$missing" "every package has a directory"
missing=$(jq -r '.targets // {} | (.entry_points // []) + (.ad_operations // []) | .[] | .class as $c | .methods[] | "\($c)\t\(.name)"' \
  "$R"/[!_]*.json | sort -u | while IFS="$(printf '\t')" read -r c m; do
  f="$tmp/a/smali/$(printf '%s' "$c" | tr . /).smali"
  grep -q "^\.method public static $m(" "$f" 2>/dev/null || echo "$c#$m"; done)
assert_eq "" "$missing" "every target class declares every target method"
missing=$(jq -r '.manifest_components[]?.class' "$R"/[!_]*.json | sort -u | while IFS= read -r c; do
  grep -q "android:name=\"$c\"" "$tmp/a/AndroidManifest.xml" || echo "$c"; done)
assert_eq "" "$missing" "every manifest component is declared"
n=$(python3 "$NS/registry-scan.py" "$tmp/a" --registry "$R" --depth 1 --category all --output-dir "$tmp/o" | grep -c '^MATCHED:')
assert_eq 48 "$n" "registry-scan (base registry) matches all 48 entries on synth48"
t_done
