#!/usr/bin/env bash
# tests/golden/additive-check.sh <A> <B> -- for an INTENDED neutralization change (new
# targets / manifest components in the registry), check that capture B only ADDS lines to
# the registry-scan outputs of baseline A: no line of any registry-targets.txt or
# registry-manifest.txt of A may be missing from the matching file of B (multiset).
#   A, B   a label under $ARE_GOLD or an absolute path (as for compare.sh); a synth48/ part
#          missing in A is read from tests/golden/synth48.before (G-synth).
# Prints the removed lines (if any) and the distinct added lines.
# Exit 0 = purely additive, 1 = some line was removed, 2 = bad usage.
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
export LC_ALL=C

[ $# -eq 2 ] || { echo "usage: additive-check.sh <A> <B>" >&2; exit 2; }
resolve() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s\n' "$ARE_GOLD/$1" ;; esac; }
A=$(resolve "$1"); B=$(resolve "$2")
[ -d "$A" ] && [ -d "$B" ] || { echo "additive-check: missing capture: $A or $B" >&2; exit 2; }
SYNTH=$TESTS_DIR/golden/synth48.before

mktemp_dir tmp
: >"$tmp/removed"; : >"$tmp/added"
n=0
while IFS= read -r f; do
  rel=${f#"$B"/}
  case "$rel" in
    synth48/*) [ -d "$A/synth48" ] && base=$A/$rel || base=$SYNTH/${rel#synth48/} ;;
    *) base=$A/$rel ;;
  esac
  [ -f "$base" ] || { echo "additive-check: no baseline for $rel" >&2; continue; }
  n=$((n + 1))
  grep -v -e '^#' -e '^[[:space:]]*$' "$base" | sort >"$tmp/a"
  grep -v -e '^#' -e '^[[:space:]]*$' "$f" | sort >"$tmp/b"
  # multiset difference: lines of A not matched one-to-one in B
  awk 'NR == FNR { c[$0]++; next } { if (c[$0] > 0) c[$0]--; else print }' "$tmp/b" "$tmp/a" |
    sed "s#^#$rel: #" >>"$tmp/removed"
  awk 'NR == FNR { c[$0]++; next } { if (c[$0] > 0) c[$0]--; else print }' "$tmp/a" "$tmp/b" >>"$tmp/added"
done < <(find "$B" -type f \( -name registry-targets.txt -o -name registry-manifest.txt \) | sort)

echo "additive-check: $n registry-targets/manifest files compared ($A -> $B)"
if [ -s "$tmp/removed" ]; then
  echo "REMOVED lines (not additive):"
  sed 's/^/  - /' "$tmp/removed"
fi
echo "distinct ADDED lines:"
sort -u "$tmp/added" | sed 's/^/  + /'
[ -s "$tmp/removed" ] && exit 1
echo "PURELY ADDITIVE"
exit 0
