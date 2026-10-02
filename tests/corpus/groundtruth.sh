#!/usr/bin/env bash
# groundtruth.sh -- the corpus gates of the registry-driven audit (DESIGN 9.2 "Gate"), on the
# fresh pristine apktool decodes ($ARE_PRISTINE/<app>, DESIGN Q4) and on the jadx corpus
# ($ARE_JADX/<app>; HeartStar and Water Sort from $ARE_JADX_EXTRA):
#   G-PREC  HIGH precision 1.0 per app x group x layout: every HIGH SDK is an expected
#           'high'/'medium' SDK of tests/corpus/expected-sdkids.json (or a `prec` row of
#           known-deviations.tsv)
#   G-REC   HIGH+MEDIUM recall per app x group: >= 0.95 on apktool, >= 0.90 on jadx; and
#           ironsource >= MEDIUM with files >= 800 on alto and bulldozer (jadx package alias)
#   G-HS    HeartStar: no tracker >= MEDIUM; find-ads HIGH = {unity-ads}; google-admob <= LOW
#   G-NEW   flurry HIGH on blockcraft; tiktok-business, bigo-ads, kidoz HIGH where the ground
#           truth has them at 'high'
#   G-FP-KNOWN  the `max` rows of known-deviations.tsv (DESIGN 3.6)
#   G-EP    (I24) every Entry Points file is under a prefix of tests/corpus/ep-allowlist.tsv
#           for its app (or under the app's manifest package); never under com/google/android/
#           gms, com/google/firebase, com/json, org/json. Precision = rows outside / rows = 0.
# One `--json` run per app x tool x layout (ARE_GT_JOBS parallel runs, default 4).
# An app whose tree is missing is skipped with a note; no tree at all -> SKIP.
# requires: NS/sdk-audit.sh S/tracker-analysis/scripts/find-trackers.sh S/ad-analysis/scripts/find-ads.sh
# requires: TESTS/corpus/expected-sdkids.json TESTS/corpus/known-deviations.tsv TESTS/corpus/ep-allowlist.tsv
# requires: cmd: have_jq16
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
export LC_ALL=C

EXPECTED=$TESTS_DIR/corpus/expected-sdkids.json
KNOWN=$TESTS_DIR/corpus/known-deviations.tsv
ALLOW=$TESTS_DIR/corpus/ep-allowlist.tsv
HOMEP=$(dirname "$ARE_WORKSPACE")
ARE_JADX_EXTRA=${ARE_JADX_EXTRA:-heartstar=$HOMEP/re-test5/HeartStar_1.2.5_align-decompiled|watersort=$HOMEP/re-test3/Water Sort Puzzle - Sort Color_4.20.0_APKPure-decompiled}
JOBS=${ARE_GT_JOBS:-4}
APPS=$(jq -r '.apps | keys[]' "$EXPECTED")
mktemp_dir tmp

tree_of() { # tree_of <layout> <app>
  if [ "$1" = apktool ]; then [ -d "$ARE_PRISTINE/$2" ] && echo "$ARE_PRISTINE/$2"; return 0; fi
  if [ -d "$ARE_JADX/$2" ]; then echo "$ARE_JADX/$2"; return 0; fi
  printf '%s\n' "$ARE_JADX_EXTRA" | tr '|' '\n' | awk -v a="$2" 'index($0, a "=") == 1 { print substr($0, length(a) + 2); exit }' |
    while IFS= read -r d; do [ -d "$d" ] && echo "$d"; done
}

# ---- runs --------------------------------------------------------------------------------------
: >"$tmp/jobs"
for lay in apktool jadx; do
  for a in $APPS; do
    d=$(tree_of "$lay" "$a")
    if [ -z "$d" ]; then echo "note: no $lay tree for $a"; continue; fi
    printf '%s\t%s\t%s\n' "$lay" "$a" "$d" >>"$tmp/jobs"
  done
done
[ -s "$tmp/jobs" ] || skip "no corpus tree (ARE_PRISTINE=$ARE_PRISTINE, ARE_JADX=$ARE_JADX)"
cat >"$tmp/run1.sh" <<'EOF'
# run1.sh <layout> <app> <dir> <outdir> <tool-script>...: one --json run per tool
lay=$1 a=$2 d=$3 o=$4; shift 4
for tool in "$@"; do
  tn=$(basename "$tool" .sh)
  "${BASH32:-bash}" "$tool" "$d" --json >"$o/$lay.$a.$tn.json" 2>"$o/$lay.$a.$tn.err"
  echo $? >"$o/$lay.$a.$tn.rc"
done
EOF
FT=$S/tracker-analysis/scripts/find-trackers.sh
FA=$S/ad-analysis/scripts/find-ads.sh
t0=$(date +%s)
tr '\n' '\0' <"$tmp/jobs" | xargs -0 -n 1 -P "$JOBS" sh -c '
  lay=$(printf "%s" "$1" | cut -f1); a=$(printf "%s" "$1" | cut -f2); d=$(printf "%s" "$1" | cut -f3-)
  bash "$0" "$lay" "$a" "$d" "'"$tmp"'" "'"$FT"'" "'"$FA"'"' "$tmp/run1.sh"
echo "runs: $(wc -l <"$tmp/jobs" | tr -d ' ') app x layout, 2 tools each, $(( $(date +%s) - t0 ))s"

# ---- per run: level table and entry-point paths -----------------------------------------------
# levels.tsv: layout app tool sdk_id level files group ; ep.tsv: layout app tool path-under-code-root
: >"$tmp/levels.tsv"; : >"$tmp/ep.tsv"
while IFS="$(printf '\t')" read -r lay a d; do
  for tn in find-trackers find-ads; do
    rc=$(cat "$tmp/$lay.$a.$tn.rc")
    _T_CHECKS=$((_T_CHECKS + 1))
    if [ "$rc" != 0 ] || ! jq -e . "$tmp/$lay.$a.$tn.json" >/dev/null 2>&1; then
      fail_check "$lay $a $tn --json: rc $rc or invalid JSON"; tail -n 5 "$tmp/$lay.$a.$tn.err" | sed 's/^/    /'; continue
    fi
    jq -r --arg l "$lay" --arg a "$a" --arg t "$tn" '
      ((.trackers // []) + (.ad_sdks // []) + (.consent_sdks // []))[]
      | [$l, $a, $t, .sdk_id, .confidence, (.evidence.files | tostring)] | @tsv' "$tmp/$lay.$a.$tn.json" >>"$tmp/levels.tsv"
    jq -r --arg l "$lay" --arg a "$a" --arg t "$tn" '
      .input.code_roots as $roots
      | .entry_points[] | .path as $p
      | ([$roots[] | select(. as $c | $p | startswith($c + "/"))] | max_by(length)) as $r
      | [$l, $a, $t, (if $r == null then $p else $p[($r | length) + 1:] end)] | @tsv' "$tmp/$lay.$a.$tn.json" >>"$tmp/ep.tsv"
  done
done <"$tmp/jobs"

# expected: app sdk_id expectation group
"${BASH32:-bash}" "$NS/registry-query.sh" rows >"$tmp/rows" || die "registry-query rows failed"
awk -F '\t' '$3 == "group" { print $1 "\t" $4 }' "$tmp/rows" >"$tmp/groups"
jq -r '.apps | to_entries[] | .key as $a | .value.sdks | to_entries[] | [$a, .key, .value] | @tsv' "$EXPECTED" >"$tmp/exp0"
awk -F '\t' 'NR == FNR { g[$1] = $2; next } { print $0 "\t" (($2 in g) ? g[$2] : "other") }' "$tmp/groups" "$tmp/exp0" >"$tmp/exp"
awk -F '\t' '!/^#/ && NF >= 5' "$KNOWN" >"$tmp/known"

lvl() { awk -F '\t' -v l="$1" -v a="$2" -v s="$3" '$1 == l && $2 == a && $4 == s { print $5; f = 1; exit } END { if (!f) print "NONE" }' "$tmp/levels.tsv"; }
rank() { case "$1" in HIGH) echo 3 ;; MEDIUM) echo 2 ;; LOW) echo 1 ;; *) echo 0 ;; esac; }
has_run() { grep -q "^$1	$2	" "$tmp/jobs"; }

# ---- G-PREC / G-REC ---------------------------------------------------------------------------
# tool -> groups: find-trackers = trackers, find-ads = ads + consent
awk -F '\t' '
  FILENAME == ARGV[1] { if ($3 != "residue") pos[$1, $2] = $4; exp_[$1, $2] = $3; grp[$2] = $4; next }
  FILENAME == ARGV[2] { if ($1 == "prec") prec[$2, $3] = 1; next }
  FILENAME == ARGV[3] { G[$1] = $2; next }
  {
    lay = $1; a = $2; s = $4; lv = $5; g = (s in G) ? G[s] : "other"
    if (g == "consent") g = "ads"
    seen[lay, a] = 1
    if (lv == "HIGH") {
      nh[lay, a, g]++
      if (!((a, s) in pos) && !((a, s) in prec)) { bad[lay, a, g] = bad[lay, a, g] " " s; nbad++ }
    }
    if (lv == "HIGH" || lv == "MEDIUM") found[lay, a, s] = 1
  }
  END {
    for (k in seen) {
      split(k, kk, SUBSEP); lay = kk[1]; a = kk[2]
      for (gi = 1; gi <= 2; gi++) {
        g = (gi == 1) ? "trackers" : "ads"
        np = 0; nf = 0; miss = ""
        for (p in pos) { split(p, pp, SUBSEP); if (pp[1] != a) continue
          pg = pos[p]; if (pg == "consent") pg = "ads"; if (pg != g) continue
          np++; if ((lay, a, pp[2]) in found) nf++; else miss = miss " " pp[2] }
        r = (np == 0) ? 1 : nf / np
        thr = (lay == "apktool") ? 0.95 : 0.90
        printf "%s\t%s\t%s\t%d\t%d\t%.3f\t%s\t%s\t%s\n", lay, a, g, nf, np, r, (r >= thr ? "ok" : "LOW"), miss, bad[lay, a, g]
      }
    }
  }' "$tmp/exp" "$tmp/known" "$tmp/groups" "$tmp/levels.tsv" | sort >"$tmp/pr"
echo "app x group: found/expected recall (HIGH+MEDIUM); HIGH not in the ground truth"
awk -F '\t' '{ printf "  %-8s %-11s %-9s %2d/%-2d %s %s%s%s\n", $1, $2, $3, $4, $5, $6, $7, ($8 == "" ? "" : " missing:" $8), ($9 == "" ? "" : " FALSE-HIGH:" $9) }' "$tmp/pr"
while IFS="$(printf '\t')" read -r lay a g nf np r st miss fh; do
  assert_eq "" "$fh" "G-PREC $lay $a $g: every HIGH is in the ground truth"
  assert_eq ok "$st" "G-REC $lay $a $g: recall $r ($nf/$np)${miss:+ missing:$miss}"
done <"$tmp/pr"
for a in alto bulldozer; do
  has_run jadx "$a" || continue
  l=$(lvl jadx "$a" ironsource)
  f=$(awk -F '\t' -v a="$a" '$1 == "jadx" && $2 == a && $4 == "ironsource" { print $6; exit }' "$tmp/levels.tsv")
  assert_true "G-REC jadx $a: ironsource >= MEDIUM through the package alias ($l)" [ "$(rank "$l")" -ge 2 ]
  assert_true "G-REC jadx $a: ironsource files >= 800 (${f:-0})" [ "${f:-0}" -ge 800 ]
done

# ---- G-HS -------------------------------------------------------------------------------------
for lay in apktool jadx; do
  has_run "$lay" heartstar || continue
  t=$(awk -F '\t' -v l="$lay" '$1 == l && $2 == "heartstar" && $3 == "find-trackers" && ($5 == "HIGH" || $5 == "MEDIUM") { print $4 }' "$tmp/levels.tsv" | tr '\n' ' ')
  assert_eq "" "$t" "G-HS $lay: no tracker >= MEDIUM on HeartStar"
  h=$(awk -F '\t' -v l="$lay" '$1 == l && $2 == "heartstar" && $3 == "find-ads" && $5 == "HIGH" { print $4 }' "$tmp/levels.tsv" | sort | tr '\n' ' ')
  assert_eq "unity-ads " "$h" "G-HS $lay: find-ads HIGH = {unity-ads}"
  assert_true "G-HS $lay: google-admob <= LOW" [ "$(rank "$(lvl "$lay" heartstar google-admob)")" -le 1 ]
done

# ---- G-NEW --------------------------------------------------------------------------------------
for lay in apktool jadx; do
  for pair in blockcraft:flurry; do
    a=${pair%%:*} s=${pair#*:}
    has_run "$lay" "$a" && assert_eq HIGH "$(lvl "$lay" "$a" "$s")" "G-NEW $lay $a: $s HIGH"
  done
  awk -F '\t' '($2 == "tiktok-business" || $2 == "bigo-ads" || $2 == "kidoz") && $3 == "high" { print $1 "\t" $2 }' "$tmp/exp" |
  while IFS="$(printf '\t')" read -r a s; do
    has_run "$lay" "$a" || continue
    echo "$lay	$a	$s	$(lvl "$lay" "$a" "$s")"
  done >"$tmp/gnew"
  while IFS="$(printf '\t')" read -r l a s v; do assert_eq HIGH "$v" "G-NEW $l $a: $s HIGH"; done <"$tmp/gnew"
done

# ---- G-FP-KNOWN ---------------------------------------------------------------------------------
while IFS="$(printf '\t')" read -r kind a s v why; do
  [ "$kind" = max ] || continue
  for lay in apktool jadx; do
    has_run "$lay" "$a" || continue
    l=$(lvl "$lay" "$a" "$s")
    assert_true "G-FP-KNOWN $lay $a: $s $l <= $v" [ "$(rank "$l")" -le "$(rank "$v")" ]
  done
done <"$tmp/known"

# ---- G-EP ---------------------------------------------------------------------------------------
awk -F '\t' '/^#/ || /^[ \t]*$/ { next } NF != 3 || $3 == "" { print "ep-allowlist.tsv:" FNR ": expected app<TAB>prefix<TAB>reason" }' "$ALLOW" >"$tmp/allow.bad"
assert_eq "" "$(cat "$tmp/allow.bad")" "ep-allowlist.tsv rows are well formed"
jq -r '.apps | to_entries[] | [.key, (.value.manifest_package | gsub("\\."; "/"))] | @tsv' "$EXPECTED" >"$tmp/apppkg"
awk -F '\t' '
  FILENAME == ARGV[1] { if ($0 ~ /^#/ || $0 ~ /^[ \t]*$/) next; n++; AA[n] = $1; AP[n] = $2; next }
  FILENAME == ARGV[2] { PK[$1] = $2; next }
  function under(p, x) { return index(p, x "/") == 1 }
  {
    lay = $1; a = $2; t = $3; p = $4; tot[lay, a, t]++
    forb = ""
    split("com/google/android/gms com/google/firebase com/json org/json", F, " ")
    for (i = 1; i <= 4; i++) if (under(p, F[i])) forb = F[i]
    ok = 0
    if (forb == "") {
      if ((a in PK) && under(p, PK[a])) ok = 1
      for (i = 1; i <= n && !ok; i++) {
        if (AA[i] != "*" && AA[i] != a) continue
        if (AP[i] == "<r8>") { if (p !~ /\/.*\//) { ok = 1; used[i] = 1 } }
        else if (under(p, AP[i])) { ok = 1; used[i] = 1 }
      }
    }
    if (!ok) { out[lay, a, t]++; if (!((lay, a, t, p) in shown) && nshow[lay, a, t]++ < 5) { shown[lay, a, t, p] = 1; print "X\t" lay "\t" a "\t" t "\t" p "\t" (forb == "" ? "not allowlisted" : "forbidden " forb) } }
  }
  END {
    for (k in tot) { split(k, kk, SUBSEP); print "T\t" kk[1] "\t" kk[2] "\t" kk[3] "\t" tot[k] "\t" ((k in out) ? out[k] : 0) }
    for (i = 1; i <= n; i++) if (!(i in used)) print "U\t" AA[i] "\t" AP[i]
  }' "$ALLOW" "$tmp/apppkg" "$tmp/ep.tsv" >"$tmp/gep"
awk -F '\t' '$1 == "T"' "$tmp/gep" | sort >"$tmp/gep.t"
tot=$(awk -F '\t' '{ s += $5 } END { print s + 0 }' "$tmp/gep.t"); outn=$(awk -F '\t' '{ s += $6 } END { print s + 0 }' "$tmp/gep.t")
echo "G-EP: $outn of $tot Entry Points rows outside the allowlist (ratio $(awk -v o="$outn" -v t="$tot" 'BEGIN { printf "%.4f", (t == 0 ? 0 : o / t) }'), must be 0)"
while IFS="$(printf '\t')" read -r _ lay a t n o; do
  assert_eq 0 "$o" "G-EP $lay $a $t: Entry Points rows outside ep-allowlist.tsv ($n rows)"
done <"$tmp/gep.t"
awk -F '\t' '$1 == "X" { print "    " $2 " " $3 " " $4 ": " $5 " (" $6 ")" }' "$tmp/gep"
awk -F '\t' '$1 == "U" { print "note: ep-allowlist.tsv row " $2 " " $3 " matched no Entry Points row in this run" }' "$tmp/gep"

t_done
