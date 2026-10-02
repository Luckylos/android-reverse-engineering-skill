#!/usr/bin/env bash
# find-golden.sh -- goldens of the new audit (DESIGN 9.2 golden/find): find-trackers.sh and
# find-ads.sh --tsv on every pristine apktool decode ($ARE_PRISTINE/<app>) must equal
# tests/golden/find/<app>.<tool>.tsv, committed with the engine (DESIGN 10, commit 8), so
# that any change of the audit's verdicts, evidence or calls is a visible diff. The --tsv
# rows carry no input path (paths are relative to the input), so no normalization is needed.
# ARE_UPDATE_EXPECTED=1 rewrites the goldens (review the diff before committing).
# An app without a pristine decode is skipped with a note; none at all -> SKIP.
# requires: NS/sdk-audit.sh S/tracker-analysis/scripts/find-trackers.sh S/ad-analysis/scripts/find-ads.sh
# requires: cmd: have_jq16
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
export LC_ALL=C

GD=$TESTS_DIR/golden/find
FT=$S/tracker-analysis/scripts/find-trackers.sh
FA=$S/ad-analysis/scripts/find-ads.sh
mktemp_dir tmp
[ "${ARE_UPDATE_EXPECTED:-0}" = 1 ] && mkdir -p "$GD"
n=0
for a in af1945 alto badpiggies blockcraft bulldozer heartstar subway ttom2 watersort; do
  d=$ARE_PRISTINE/$a
  if [ ! -d "$d" ]; then echo "note: no pristine decode for $a"; continue; fi
  for tool in "$FT" "$FA"; do
    tn=$(basename "$tool" .sh)
    run_bash "$tool" "$d" --tsv >"$tmp/$a.$tn.tsv" 2>"$tmp/$a.$tn.err"
    assert_eq 0 "$?" "$a $tn --tsv: rc 0"
    n=$((n + 1))
    if [ "${ARE_UPDATE_EXPECTED:-0}" = 1 ]; then cp "$tmp/$a.$tn.tsv" "$GD/$a.$tn.tsv"; continue; fi
    if [ -f "$GD/$a.$tn.tsv" ]; then assert_files_eq "$GD/$a.$tn.tsv" "$tmp/$a.$tn.tsv" "$a $tn --tsv == golden/find/$a.$tn.tsv"
    else _T_CHECKS=$((_T_CHECKS + 1)); fail_check "missing golden/find/$a.$tn.tsv"; fi
  done
done
[ "$n" -gt 0 ] || skip "no pristine decode (ARE_PRISTINE=$ARE_PRISTINE)"
t_done
