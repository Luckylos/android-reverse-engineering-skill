#!/usr/bin/env bash
# tests/golden/compare.sh <A> <B> -- byte-compare two captures made by capture.sh (or by
# the original scratch/contract/golden.sh). Port of scratch/contract/compare.sh.
#   A, B   a label under $ARE_GOLD (e.g. `before`, `after`) or an absolute path:
#          compare.sh before after      compare.sh "$ARE_GOLD/before" /tmp/x/after
# A is the baseline. When A has no subtree for a part that B has, the part is compared
# with its own frozen baseline instead of being reported as extra:
#   synth48/                 -> tests/golden/synth48.before/  (G-synth, captured in commit 0)
#   adwrapper-noreg/<app>/   -> A/adwrapper/<app>/  (default registry resolution must give
#                               exactly the --registry output, I8)
#   adwrapper-ps1/, adwrapper-ps1-noreg/ <app>.{norm,stderr}
#                            -> $ARE_GOLD/adwrapper-ps1-before/<app>.{norm,stderr}
# Prints one line per differing file plus a unified diff (first 40 lines each).
# Exit 0 = byte-identical (prints IDENTICAL), 1 = differences, 2 = bad usage.
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
export LC_ALL=C

resolve() { case "$1" in /*) printf '%s\n' "${1%/}" ;; *) printf '%s\n' "$ARE_GOLD/$1" ;; esac; }
[ $# -eq 2 ] || { echo "usage: compare.sh <labelA|/abs/A> <labelB|/abs/B>" >&2; exit 2; }
A=$(resolve "$1"); B=$(resolve "$2")
[ -d "$A" ] || { echo "compare.sh: not found: $A" >&2; exit 2; }
[ -d "$B" ] || { echo "compare.sh: not found: $B" >&2; exit 2; }
SYNTH_BASE=$TESTS_DIR/golden/synth48.before
PS_BASE=$ARE_GOLD/adwrapper-ps1-before

mktemp_dir tmp
# pairs: <rel>\t<baseline-file>\t<candidate-file>
: >"$tmp/pairs"
add_tree() { # add_tree <baseline-root> <candidate-root> <rel-prefix> [find-name-args...]
  local base=$1 cand=$2 pfx=$3; shift 3
  { (cd "$base" 2>/dev/null && find . -type f "$@"); (cd "$cand" 2>/dev/null && find . -type f "$@"); } |
    sed 's#^\./##' | sort -u | while IFS= read -r r; do
      printf '%s%s\t%s/%s\t%s/%s\n' "$pfx" "$r" "$base" "$r" "$cand" "$r"
    done >>"$tmp/pairs"
}
tops=$( { (cd "$A" && find . -mindepth 1 -maxdepth 1 -type d); (cd "$B" && find . -mindepth 1 -maxdepth 1 -type d); } |
        sed 's#^\./##' | sort -u)
for t in $tops; do
  if [ -d "$A/$t" ] || [ ! -d "$B/$t" ]; then add_tree "$A/$t" "$B/$t" "$t/"; continue; fi
  case "$t" in
    synth48) add_tree "$SYNTH_BASE" "$B/$t" "$t/" ;;
    adwrapper-noreg) add_tree "$A/adwrapper" "$B/$t" "$t/" ;;
    adwrapper-ps1|adwrapper-ps1-noreg)
      add_tree "$PS_BASE" "$B/$t" "$t/" '(' -name '*.norm' -o -name '*.stderr' -o -name '*.EXIT_*' ')' ;;
    *) add_tree "$A/$t" "$B/$t" "$t/" ;;
  esac
done
# loose files at the top level (none expected)
{ (cd "$A" && find . -mindepth 1 -maxdepth 1 -type f); (cd "$B" && find . -mindepth 1 -maxdepth 1 -type f); } |
  sed 's#^\./##' | sort -u | while IFS= read -r r; do printf '%s\t%s/%s\t%s/%s\n' "$r" "$A" "$r" "$B" "$r"; done >>"$tmp/pairs"

rc=0; n=0
while IFS="$(printf '\t')" read -r rel base cand; do
  n=$((n + 1))
  if [ ! -f "$base" ]; then rc=1; echo "DIFF: $rel (only in candidate)"; continue; fi
  if [ ! -f "$cand" ]; then rc=1; echo "DIFF: $rel (missing in candidate)"; continue; fi
  if ! cmp -s "$base" "$cand"; then
    rc=1; echo "DIFF: $rel"
    diff -u "$base" "$cand" 2>&1 | head -40 | sed 's/^/    /'
  fi
done <"$tmp/pairs"
[ "$n" -gt 0 ] || { echo "compare.sh: nothing to compare" >&2; exit 1; }
[ "$rc" -eq 0 ] && echo "IDENTICAL: $1 == $2 ($n files)"
exit $rc
