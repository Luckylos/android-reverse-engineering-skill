#!/usr/bin/env bash
# t_format.sh -- T-FORMAT (DESIGN 2.3): every (class, method) pair of the ads /
# ads_mediation entries -- targets (target_api rows) and detection.apis (api rows) --
# gets an ad format from the tables of REG/_audit-shared.json, or is listed in
# format_none. Rules, in order: (1) exact simple class name in format_by_class ('-' = no
# format); (2) first token of format_by_class_token contained in the simple class name;
# (3) first token of format_by_method_token contained in the method name. The simple
# name is the text after the last '.' of the FQCN. A new ads pair without a format thus
# fails here instead of silently vanishing from --formats.
# Also: format_none has no stale entry (every item is a current ads pair) and no entry
# that a rule already maps; the token tables are ordered specific-before-generic (a
# token never follows another token it contains).
# requires: NS/registry-query.sh REG/_audit-shared.json
# requires: cmd: have_jq16
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
export LC_ALL=C

mktemp_dir tmp
run_bash "$NS/registry-query.sh" --registry "$REG" shared >"$tmp/shared" 2>&1 || die "registry-query shared failed: $(head -n 3 "$tmp/shared")"
run_bash "$NS/registry-query.sh" --registry "$REG" rows >"$tmp/rows" 2>&1 || die "registry-query rows failed: $(head -n 3 "$tmp/rows")"

# ads pairs "FQCN#method" (unique, first-seen order)
awk -F '\t' '$3 == "group" { grp[$1] = $4 }
  ($3 == "target_api" || $3 == "api") && grp[$1] == "ads" { split($4, a, " "); k = a[1] "#" a[2]; if (!(k in s)) { s[k] = 1; print k } }' \
  "$tmp/rows" >"$tmp/pairs"
[ -s "$tmp/pairs" ] || die "no ads pair found in the registry rows"

# format of each pair ("" = none), with the shared tables
awk -F '\t' '
  NR == FNR {
    if ($1 != "format_token") next
    split($3, kv, " ")
    if ($2 == "by_class") { cls[kv[1]] = kv[2]; has_cls[kv[1]] = 1 }
    else if ($2 == "by_class_token") { nct++; ctok[nct] = kv[1]; cfmt[nct] = kv[2] }
    else if ($2 == "by_method_token") { nmt++; mtok[nmt] = kv[1]; mfmt[nmt] = kv[2] }
    else if ($2 == "none") none[$3] = 1
    next
  }
  {
    split($0, pm, "#"); c = pm[1]; m = pm[2]
    sn = c; sub(/.*[.]/, "", sn)
    fmt = ""
    if (sn in has_cls) fmt = cls[sn]
    if (fmt == "") for (i = 1; i <= nct; i++) if (index(sn, ctok[i])) { fmt = cfmt[i]; break }
    if (fmt == "") for (i = 1; i <= nmt; i++) if (index(m, mtok[i])) { fmt = mfmt[i]; break }
    print $0 "\t" (fmt == "" ? "?" : fmt) "\t" (($0 in none) ? "none" : "-")
  }' "$tmp/shared" "$tmp/pairs" >"$tmp/formats"

assert_eq "" "$(awk -F '\t' '$2 == "?" && $3 != "none" { print $1 }' "$tmp/formats" | head -n 20)" \
  "every ads (class, method) pair has a format or is in format_none"
assert_eq "" "$(awk -F '\t' '$2 != "?" && $3 == "none" { print $1 " -> " $2 }' "$tmp/formats")" \
  "format_none lists no pair that a rule already maps"
awk -F '\t' '$1 == "format_token" && $2 == "none" { print $3 }' "$tmp/shared" | sort >"$tmp/none"
cut -f1 "$tmp/pairs" | sort >"$tmp/pairs.sorted"
assert_eq "" "$(comm -23 "$tmp/none" "$tmp/pairs.sorted")" "format_none has no stale entry (every item is a current ads pair)"
assert_eq "" "$(sort "$tmp/none" | uniq -d)" "format_none has no duplicate"
for table in by_class_token by_method_token; do
  awk -F '\t' -v t="$table" '$1 == "format_token" && $2 == t { split($3, kv, " "); n++; tok[n] = kv[1] }
    END { for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (index(tok[j], tok[i])) print tok[j] " after " tok[i] }' \
    "$tmp/shared" >"$tmp/order"
  assert_eq "" "$(cat "$tmp/order")" "$table: specific tokens come before the generic ones they contain"
done
# spot checks from the design (2.3)
for c in 'com.mbridge.msdk.out.MBRewardVideoHandler#x rewarded' 'com.x.TTFullScreenVideoAd#x interstitial' \
         'com.my.target.ads.MyTargetView#x banner' 'com.tapjoy.TJPlacement#requestContent -' \
         'com.ironsource.mediationsdk.IronSource#showInterstitial interstitial' 'com.x.MaxAdView#loadAd banner' \
         'com.x.RewardedInterstitialAd#load rewarded_interstitial' 'com.x.OguryOptinVideoAd#load rewarded'; do
  pair=${c% *}; want=${c##* }
  got=$(printf '%s\n' "$pair" | awk -F '\t' '
    NR == FNR { if ($1 != "format_token") next; split($3, kv, " ")
      if ($2 == "by_class") { cls[kv[1]] = kv[2]; h[kv[1]] = 1 } else if ($2 == "by_class_token") { n++; ct[n] = kv[1]; cf[n] = kv[2] }
      else if ($2 == "by_method_token") { k++; mt[k] = kv[1]; mf[k] = kv[2] }; next }
    { split($0, pm, "#"); sn = pm[1]; sub(/.*[.]/, "", sn); f = ""
      if (sn in h) f = cls[sn]
      if (f == "") for (i = 1; i <= n; i++) if (index(sn, ct[i])) { f = cf[i]; break }
      if (f == "") for (i = 1; i <= k; i++) if (index(pm[2], mt[i])) { f = mf[i]; break }
      print f }' "$tmp/shared" -)
  assert_eq "$want" "$got" "format of $pair"
done
echo "ads pairs: $(wc -l <"$tmp/pairs" | tr -d ' ') ($(awk -F '\t' '$2 != "?"' "$tmp/formats" | wc -l | tr -d ' ') with a format, $(wc -l <"$tmp/none" | tr -d ' ') in format_none)"
t_done
