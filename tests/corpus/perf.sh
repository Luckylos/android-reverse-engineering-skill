#!/usr/bin/env bash
# perf.sh -- time budget of the sh audit engine (DESIGN 5.4 "Performance"): WARN beyond the
# budget, never FAIL (exit 0 even then). Each case runs find-ads.sh and find-trackers.sh
# --tsv once (the first run on a cold tree also measures the disk cache):
#   HeartStar jadx < 1 s, Subway apktool < 10 s, Water Sort jadx < 10 s.
# Trees: $ARE_PRISTINE/subway (apktool), the HeartStar and Water Sort jadx outputs of
# $ARE_JADX_EXTRA (as in groundtruth.sh). SKIP when none exists.
# requires: NS/sdk-audit.sh S/tracker-analysis/scripts/find-trackers.sh S/ad-analysis/scripts/find-ads.sh
# requires: cmd: have_jq16
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
export LC_ALL=C

HOMEP=$(dirname "$ARE_WORKSPACE")
ARE_JADX_EXTRA=${ARE_JADX_EXTRA:-heartstar=$HOMEP/re-test5/HeartStar_1.2.5_align-decompiled|watersort=$HOMEP/re-test3/Water Sort Puzzle - Sort Color_4.20.0_APKPure-decompiled}
extra() { printf '%s\n' "$ARE_JADX_EXTRA" | tr '|' '\n' | awk -v a="$1" 'index($0, a "=") == 1 { print substr($0, length(a) + 2); exit }'; }
FT=$S/tracker-analysis/scripts/find-trackers.sh
FA=$S/ad-analysis/scripts/find-ads.sh
now() { date +%s.%N 2>/dev/null | awk '{ print ($0 ~ /N/) ? int($0) : $0 }'; }

ran=0; warn=0
printf '%s\n' "heartstar-jadx|$(extra heartstar)|1" "subway-apktool|$ARE_PRISTINE/subway|10" \
  "watersort-jadx|$(extra watersort)|10" >"${TMPDIR:-/tmp}/are-perf.$$"
while IFS='|' read -r name dir budget; do
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then echo "note: $name: no tree (${dir:-unset})"; continue; fi
  for tool in "$FA" "$FT"; do
    t0=$(now)
    run_bash "$tool" "$dir" --tsv >/dev/null 2>&1
    rc=$?
    t1=$(now)
    dt=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", b - a }')
    ran=$((ran + 1))
    if [ "$rc" != 0 ]; then echo "WARN: $name $(basename "$tool"): rc $rc"; warn=$((warn + 1))
    elif awk -v d="$dt" -v b="$budget" 'BEGIN { exit !(d > b) }'; then
      echo "WARN: $name $(basename "$tool"): ${dt}s (budget ${budget}s)"; warn=$((warn + 1))
    else echo "ok: $name $(basename "$tool"): ${dt}s (budget ${budget}s)"; fi
  done
done <"${TMPDIR:-/tmp}/are-perf.$$"
rm -f "${TMPDIR:-/tmp}/are-perf.$$"
[ "$ran" -gt 0 ] || skip "no perf tree found"
echo "perf: $ran run(s), $warn over budget (WARN only)"
exit 0
