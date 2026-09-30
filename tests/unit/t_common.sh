#!/usr/bin/env bash
# t_common.sh -- self-test of tests/lib/common.sh helpers: mktemp_dir must remove exactly
# its own dirs at exit even when TMPDIR contains spaces or glob characters (a sibling
# "prefix before the space" dir must survive), and must keep the script's exit code.
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

mktemp_dir tmp
base="$tmp/my dir *x"
mkdir -p "$base" "$tmp/my" "$tmp/cwd/dir"
: >"$tmp/my/keep.txt"; : >"$tmp/cwd/dir/keep.txt"
cat >"$tmp/child.sh" <<EOF
. "$TESTS_DIR/lib/common.sh"
mktemp_dir a; mktemp_dir b
printf '%s\n' "\$a" "\$b" >"$tmp/paths"
: >"\$a/f"; mkdir "\$b/sub"
exit 3
EOF
(cd "$tmp/cwd" && TMPDIR="$base" run_bash "$tmp/child.sh"); rc=$?
assert_eq 3 "$rc" "EXIT trap keeps the script exit code"
assert_eq 2 "$(grep -F -c "$base/are-tests." "$tmp/paths")" "temp dirs created under the spaced TMPDIR"
left=0
while IFS= read -r p; do [ -e "$p" ] && left=$((left + 1)); done <"$tmp/paths"
assert_eq 0 "$left" "both temp dirs removed at exit"
assert_eq 0 "$(ls -A "$base" | wc -l | tr -d ' ')" "nothing left in the spaced TMPDIR"
assert_true "sibling prefix dir survives" test -f "$tmp/my/keep.txt"
assert_true "cwd-relative look-alike survives" test -f "$tmp/cwd/dir/keep.txt"
t_done
