#!/usr/bin/env bash
# t_tokens.sh -- T-TOKENS (DESIGN 3.5, "ogni pattern ha una casa"): every regex alternative
# of the legacy find-trackers.sh / find-ads.sh (git show $ARE_BASE_COMMIT) is a row of
# tests/fixtures/legacy-tokens.tsv, and every row is such a token, so no legacy token is
# lost silently. Extraction: the argument of every run_grep / run_grep_xml, the
# ENTRYPOINT_PATTERN and every --exclude-dir="..." item; a pattern is split on its
# outermost alternation group (the text around that group is dropped), a nested
# alternation inside an alternative is expanded in place.
# Each row's home (column 2) must also resolve against the registry under test
# (registry-query rows/shared): the API, domain, manifest name, id prefix, hint, format
# or library root it names exists; ownership/dismissed rows carry a note.
# requires: NS/registry-query.sh TESTS/fixtures/legacy-tokens.tsv
# requires: cmd: git -C "$REPO" cat-file -e "$ARE_BASE_COMMIT^{commit}"
# requires: cmd: have_jq16
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
export LC_ALL=C

TSV=$TESTS_DIR/fixtures/legacy-tokens.tsv
mktemp_dir tmp

cat >"$tmp/extract.awk" <<'AWK'
# scan(p, i): index after the character class or escape starting at i (or i + 1)
function skip(p, i,   c) {
  c = substr(p, i, 1)
  if (c == "\\") return i + 2
  if (c == "[") { while (i <= length(p) && substr(p, i, 1) != "]") i++; return i + 1 }
  return i + 1
}
# alts(p, out): split p on its depth-0 "|"; returns the count (1 = no alternation)
function alts(p, out,   i, c, d, n, st) {
  d = 0; n = 0; st = 1; i = 1
  while (i <= length(p)) {
    c = substr(p, i, 1)
    if (c == "\\" || c == "[") { i = skip(p, i); continue }
    if (c == "(") d++
    else if (c == ")") d--
    else if (c == "|" && d == 0) { n++; out[n] = substr(p, st, i - st); st = i + 1 }
    i++
  }
  n++; out[n] = substr(p, st)
  return n
}
# group(p): finds the first depth-0 group of p whose content has an alternation; sets
# G_PRE, G_IN, G_SUF and returns 1, else 0
function group(p,   i, c, d, g0, tmp) {
  d = 0; i = 1
  while (i <= length(p)) {
    c = substr(p, i, 1)
    if (c == "\\" || c == "[") { i = skip(p, i); continue }
    if (c == "(") { if (d == 0) g0 = i; d++ }
    else if (c == ")") {
      d--
      if (d == 0) {
        G_IN = substr(p, g0 + 1, i - g0 - 1)
        if (alts(G_IN, tmp) > 1) { G_PRE = substr(p, 1, g0 - 1); G_SUF = substr(p, i + 1); return 1 }
      }
    }
    i++
  }
  return 0
}
# expand(p): an alternative; a nested alternation group is expanded in place
function expand(p,   pre, suf, n, a, k) {
  if (!group(p)) { print p; return }
  pre = G_PRE; suf = G_SUF
  n = alts(G_IN, a)
  for (k = 1; k <= n; k++) expand(pre a[k] suf)
}
# top(p): the pattern of one run_grep; the outermost alternation (top level, else the
# first group that has one) gives the tokens, the text around that group is dropped
function top(p,   n, a, k) {
  n = alts(p, a)
  if (n > 1) { for (k = 1; k <= n; k++) expand(a[k]); return }
  if (!group(p)) { print p; return }
  n = alts(G_IN, a)
  for (k = 1; k <= n; k++) expand(a[k])
}
{
  if (match($0, /run_grep(_xml)? '[^']*'/)) {
    p = substr($0, RSTART, RLENGTH); sub(/^run_grep(_xml)? '/, "", p); sub(/'$/, "", p); top(p); next
  }
  if (match($0, /ENTRYPOINT_PATTERN='[^']*'/)) {
    p = substr($0, RSTART, RLENGTH); sub(/^ENTRYPOINT_PATTERN='/, "", p); sub(/'$/, "", p); top(p); next
  }
  if (match($0, /--exclude-dir="[^"]*"/)) {
    p = substr($0, RSTART, RLENGTH); sub(/"$/, "", p); sub(/="/, "=", p); print p
  }
}
AWK

: >"$tmp/legacy"
for t in tracker-analysis/scripts/find-trackers.sh ad-analysis/scripts/find-ads.sh; do
  git -C "$REPO" show "$ARE_BASE_COMMIT:plugins/android-reverse-engineering/skills/$t" >"$tmp/src" ||
    die "git show $ARE_BASE_COMMIT:$t failed"
  awk -f "$tmp/extract.awk" "$tmp/src" >>"$tmp/legacy" || die "token extraction failed on $t"
done
sort -u "$tmp/legacy" >"$tmp/legacy.set"
n=$(wc -l <"$tmp/legacy.set" | tr -d ' ')
echo "legacy tokens: $n distinct ($(wc -l <"$tmp/legacy" | tr -d ' ') extracted)"
# extractor sanity: known tokens, alternation fully split, nested groups expanded
assert_true "extractor: more than 400 distinct tokens" [ "$n" -gt 400 ]
for t in 'FirebaseAnalytics\.getInstance' 'app\.adjust\.world' 'trackEvent' '--exclude-dir=io/vungle' 'PAGSdk\.init' 'Identify\s*\(\)'; do
  assert_true "extractor: token $t" grep -qxF -- "$t" "$tmp/legacy.set"
done
assert_eq "" "$(grep -F '|' "$tmp/legacy.set")" "extractor: no token keeps an alternation"

# ---- the TSV ----------------------------------------------------------------------------
awk -F '\t' '/^#/ || /^[ \t]*$/ { next } { print FNR "\t" NF "\t" $0 }' "$TSV" >"$tmp/rows"
cut -f3 "$tmp/rows" | sort >"$tmp/tsv.tokens"
sort -u "$tmp/tsv.tokens" >"$tmp/tsv.set"
assert_eq "" "$(uniq -d "$tmp/tsv.tokens")" "legacy-tokens.tsv: every token is on one row only"
assert_eq "" "$(comm -23 "$tmp/legacy.set" "$tmp/tsv.set")" "legacy tokens without a row in legacy-tokens.tsv"
assert_eq "" "$(comm -13 "$tmp/legacy.set" "$tmp/tsv.set")" "legacy-tokens.tsv rows that are not legacy tokens"

# ---- homes resolve against the registry under test ---------------------------------------
"${BASH32:-bash}" "$NS/registry-query.sh" --registry "$REG" rows >"$tmp/reg.rows" || die "registry-query rows failed"
"${BASH32:-bash}" "$NS/registry-query.sh" --registry "$REG" shared >"$tmp/reg.shared" || die "registry-query shared failed"
awk -F '\t' '
  FILENAME == ARGV[1] {
    s = $1; f = $3; v = $4; ID[s] = 1
    if (f == "package" || f == "extra_package") IDN[s] = 1
    else if (f == "namespace_root") NSR[s] = 1
    else if (f == "adapter_package") ADP[s] = 1
    else if (f == "domain") DOM[s, v] = 1
    else if (f == "manifest_name") MN[s, v] = 1
    else if (f == "id_prefix") { split(v, a, " "); IDP[s, a[1]] = 1 }
    else if (f == "api" || f == "target_api") { split(v, a, " "); c = a[1]; sub(/^.*\./, "", c); API[s, c "#" a[2]] = 1 }
    next
  }
  FILENAME == ARGV[2] {
    if ($1 == "hint_meta") HINT[$2] = 1
    else if ($1 == "library_root") LIB[$3] = 1
    else if ($1 == "format_token") { n = split($3, a, " "); FMT[a[n]] = 1 }
    next
  }
  {
    ln = $1; nf = $2; tok = $3; home = $4; note = $5
    bad = ""
    if (nf != 3) bad = "expected token<TAB>home<TAB>note"
    else {
      n = split(home, h, ":")
      k = h[1]; a1 = h[2]; a2 = substr(home, length(k) + length(a1) + 3)
      if (k == "api") { if (!((a1, a2) in API)) bad = "no api/target " a2 " in entry " a1 }
      else if (k == "ref") { if (!(a1 in ID)) bad = "unknown entry " a1 }
      else if (k == "identity") { if (!(a1 in IDN)) bad = "entry " a1 " has no identity package" }
      else if (k == "namespace") { if (!(a1 in NSR)) bad = "entry " a1 " has no namespace_roots" }
      else if (k == "adapter") { if (!(a1 in ADP)) bad = "entry " a1 " has no adapter_packages" }
      else if (k == "domain") { if (!((a1, a2) in DOM)) bad = "no domain " a2 " in entry " a1 }
      else if (k == "manifest_name") { if (!((a1, a2) in MN)) bad = "no manifest_name " a2 " in entry " a1 }
      else if (k == "id_prefix") { if (!((a1, a2) in IDP)) bad = "no id_prefix " a2 " in entry " a1 }
      else if (k == "hint") { if (!(a1 in HINT)) bad = "unknown hint " a1 }
      else if (k == "format") { if (!(a1 in FMT)) bad = "unknown ad format " a1 }
      else if (k == "library") { if (!(a1 in LIB)) bad = "not a library_root: " a1 }
      else if (k == "ownership" || k == "dismissed") { if (n != 1 || note == "" || note == "-") bad = k " needs a note and no argument" }
      else bad = "unknown home kind " k
      if (note == "") bad = bad (bad == "" ? "" : "; ") "empty note (use -)"
    }
    if (bad != "") print "legacy-tokens.tsv:" ln ": " tok ": " bad
  }' "$tmp/reg.rows" "$tmp/reg.shared" "$tmp/rows" >"$tmp/bad"
_T_CHECKS=$((_T_CHECKS + 1))
if [ -s "$tmp/bad" ]; then fail_check "homes that do not resolve:"; sed 's/^/    /' "$tmp/bad"
else pass_check "every home resolves"; fi
echo "homes: $(awk -F '\t' '{ split($4, h, ":"); c[h[1]]++ } END { for (k in c) print k "=" c[k] }' "$tmp/rows" | sort | tr '\n' ' ')"
t_done
