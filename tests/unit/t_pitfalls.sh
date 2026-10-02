#!/usr/bin/env bash
# t_pitfalls.sh -- fixtures that the new audit (find-trackers / find-ads on the sdk-audit
# engine, DESIGN 5) MUST get right; each is a false positive or negative of the legacy
# scripts (DESIGN 9.2). Fixtures: tests/fixtures/pitfalls/make-pitfalls.sh (same case ids).
#
# Assertions only rely on the output contracts fixed by DESIGN 5.5:
#   --tsv   `SDK<TAB>sdk_id<TAB>category<TAB>LEVEL<TAB>STATUS...` (one line per entry of the
#           tool group, NONE included), `EV<TAB>sdk_id<TAB>kind<TAB>...`,
#           `CALL<TAB>sdk_id<TAB>role<TAB>FQCN#method<TAB>path:line`
#   text    `==== <Section> ====` headers, `path:line:text` rows, `=== Search complete ===`
# Entry Points rows exclude the two historical footer lines (NOTE: ... / If no results ...).
# requires: NS/sdk-audit.sh
# requires: cmd: have_jq16
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

FT=$S/tracker-analysis/scripts/find-trackers.sh
FA=$S/ad-analysis/scripts/find-ads.sh
mktemp_dir tmp
F=$tmp/fx
bash "$TESTS_DIR/fixtures/pitfalls/make-pitfalls.sh" "$F" >/dev/null || die "make-pitfalls.sh failed"

# run <tool-script> <case> <tag> [args...]: stdout -> $tmp/<case>.<tag>, rc must be 0
run() {
  _tool=$1 _case=$2 _tag=$3; shift 3
  run_bash "$_tool" "$F/$_case" "$@" >"$tmp/$_case.$_tag" 2>"$tmp/$_case.$_tag.err"
  assert_eq 0 "$?" "$_case: $(basename "$_tool") $* exits 0"
}
level() { awk -F '\t' -v s="$2" '$1 == "SDK" && $2 == s { print $4; exit }' "$1"; }
assert_level() { # assert_level <tsv> <sdk_id> <allowed levels...>
  _f=$1 _s=$2; shift 2
  _l=$(level "$_f" "$_s")
  _T_CHECKS=$((_T_CHECKS + 1))
  case " $* " in
    *" $_l "*) [ -n "$_l" ] && pass_check "$(basename "$_f"): $_s is $_l" ;;
    *) fail_check "$(basename "$_f"): $_s is '${_l:-<no SDK line>}', expected one of: $*" ;;
  esac
}
has_call() { # has_call <tsv> <sdk_id> <role> <method> <path-suffix>
  awk -F '\t' -v s="$2" -v r="$3" -v m="#$4" -v p="$5" '
    $1 == "CALL" && $2 == s && $3 == r && substr($4, length($4) - length(m) + 1) == m {
      sub(/:[0-9]+$/, "", $5); if (substr($5, length($5) - length(p) + 1) == p) { found = 1 } }
    END { exit !found }' "$1"
}
calls_in_file() { # calls_in_file <tsv> <path-suffix> -> CALL lines whose path ends with it
  awk -F '\t' -v p="$2" '$1 == "CALL" { f = $5; sub(/:[0-9]+$/, "", f)
    if (substr(f, length(f) - length(p) + 1) == p) print }' "$1"
}
section() { # section <text-output> <exact title> -> the rows of that section
  awk -v t="==== $2 ====" '
    $0 == t { on = 1; next }
    on && (/^==== .* ====$/ || /^=== Search complete ===$/) { on = 0 }
    on && NF { print }' "$1"
}
entry_points() { # rows of every "Entry Points — ..." section (without the two historical
  # footer lines "NOTE: Only calls from app code ..." / "If no results appear, ...")
  awk '/^==== Entry Points/ { on = 1; next }
       on && (/^==== .* ====$/ || /^=== Search complete ===$/) { on = 0 }
       on && NF && !/^NOTE:/ && !/^If no results appear, / { print }' "$1"
}

# P01
c=p01-firebase-getinstance-args
run "$FT" $c tsv --tsv
assert_true "$c: CALL firebase-analytics init FirebaseAnalytics#getInstance in MainActivity.java" \
  has_call "$tmp/$c.tsv" firebase-analytics init getInstance com/example/app/MainActivity.java
assert_level "$tmp/$c.tsv" firebase-analytics HIGH

# P02
c=p02-admob-id-digits
run "$FA" $c txt --admob
section "$tmp/$c.txt" "AdMob — Ad Unit IDs" >"$tmp/$c.sec"
assert_true "$c: 'AdMob — Ad Unit IDs' lists the ca-app-pub- id followed by digits" \
  grep -q 'AdConfig.java:[0-9][0-9]*:.*ca-app-pub-1234567890123456' "$tmp/$c.sec"

# P03
c=p03-jadx-multiline-manifest
run "$FA" $c tsv --tsv
assert_true "$c: manifest evidence for AdActivity (android:name on its own line)" \
  grep -q "$(printf 'EV\tgoogle-admob\tmanifest\t.*com.google.android.gms.ads.AdActivity')" "$tmp/$c.tsv"
assert_level "$tmp/$c.tsv" google-admob MEDIUM

# P04
c=p04-safedk-sdk-strings
run "$FT" $c tsv --tsv
for s in mixpanel adjust appsflyer amplitude braze; do assert_level "$tmp/$c.tsv" $s NONE; done
run "$FA" $c ads.tsv --tsv
assert_level "$tmp/$c.ads.tsv" unity-ads NONE

# P05
c=p05-guru-analytics-builder
run "$FT" $c tsv --tsv
assert_level "$tmp/$c.tsv" segment NONE
assert_eq "" "$(awk -F '\t' '$1 == "CALL" && $2 == "segment"' "$tmp/$c.tsv")" "$c: no Segment call"

# P06
c=p06-firebase-param-in-bytedance
run "$FT" $c tsv --tsv
assert_level "$tmp/$c.tsv" firebase-analytics NONE

# P07
c=p07-gms-ads-identifier-only
run "$FA" $c tsv --tsv
assert_level "$tmp/$c.tsv" google-admob NONE LOW

# P08
c=p08-facebook-ads-only
run "$FT" $c tsv --tsv
assert_level "$tmp/$c.tsv" facebook NONE LOW MEDIUM
run "$FA" $c ads.tsv --tsv
assert_level "$tmp/$c.ads.tsv" meta-audience-network HIGH

# P09
c=p09-explorestack-protobuf
run "$FA" $c tsv --tsv
assert_level "$tmp/$c.tsv" appodeal NONE

# P10
c=p10-tapjoy-manifest-only
run "$FA" $c tsv --tsv
assert_level "$tmp/$c.tsv" tapjoy MEDIUM

# P11
c=p11-firebase-logevent-instance
run "$FT" $c tsv --tsv
assert_true "$c: import-scoped CALL firebase-analytics event #logEvent in WithImport.java" \
  has_call "$tmp/$c.tsv" firebase-analytics event logEvent com/example/app/WithImport.java
assert_eq "" "$(calls_in_file "$tmp/$c.tsv" com/example/app/NoImport.java)" "$c: no call from NoImport.java (HeartStar case)"
run "$FT" $c txt --firebase
section "$tmp/$c.txt" "Firebase Analytics — Event Tracking" >"$tmp/$c.sec"
assert_true "$c: 'Firebase Analytics — Event Tracking' has the WithImport.java call" grep -q 'WithImport.java:[0-9]' "$tmp/$c.sec"
assert_false "$c: 'Firebase Analytics — Event Tracking' has nothing from NoImport.java" grep -q 'NoImport.java' "$tmp/$c.sec"

# P12
c=p12-flurry-builder-chain
run "$FT" $c tsv --tsv
_T_CHECKS=$((_T_CHECKS + 1))
if calls_in_file "$tmp/$c.tsv" com/example/app/App.java | awk -F '\t' '$2 == "flurry" && $3 == "init"' | grep -q .; then
  pass_check "$c: Flurry init call"; else fail_check "$c: no CALL flurry init from App.java"; fi

# P13
c=p13-coppa
run "$FA" $c txt --consent
section "$tmp/$c.txt" "Consent — COPPA / Child-Directed" >"$tmp/$c.sec"
assert_true "$c: COPPA section has TAG_FOR_CHILD_DIRECTED_TREATMENT_TRUE" grep -q 'TAG_FOR_CHILD_DIRECTED_TREATMENT_TRUE' "$tmp/$c.sec"
assert_true "$c: COPPA section has setCOPPA(" grep -q 'setCOPPA(' "$tmp/$c.sec"

# P14 / P15: jadx package aliases
for c in p14-jadx-alias-com-json p15-jadx-alias-org-json; do
  case $c in p14*) P=com/json ;; *) P=org/json ;; esac
  run "$FA" $c tsv --tsv
  assert_level "$tmp/$c.tsv" ironsource HIGH
  run "$FA" $c txt --entrypoints
  entry_points "$tmp/$c.txt" >"$tmp/$c.ep"
  assert_eq "" "$(grep "/$P/" "$tmp/$c.ep")" "$c: no $P rows in Entry Points"
  assert_true "$c: Entry Points has the app-code reference to IronSource" grep -q 'com/example/app/Ads.java:[0-9]' "$tmp/$c.ep"
done

# P16
c=p16-facebook-soloader-only
run "$FT" $c tsv --tsv
assert_level "$tmp/$c.tsv" facebook NONE
run "$FT" $c txt --entrypoints
assert_eq "" "$(entry_points "$tmp/$c.txt")" "$c: Entry Points is empty"

# P17
c=p17-gms-internal-refs-ads
run "$FA" $c txt --entrypoints
assert_eq "" "$(entry_points "$tmp/$c.txt")" "$c: gms/internal is library, Entry Points is empty"

# P18
c=p18-fcm-receiver-only
run "$FT" $c tsv --tsv
assert_level "$tmp/$c.tsv" firebase-analytics NONE

# P19
c=p19-wildcard-import
run "$FA" $c tsv --tsv
assert_true "$c: exact CALL google-admob init MobileAds#initialize in WildAds.java (import pkg.*)" \
  has_call "$tmp/$c.tsv" google-admob init initialize com/example/app/WildAds.java
assert_eq "exact" "$(calls_in_file "$tmp/$c.tsv" com/example/app/WildAds.java | awk -F '\t' '$4 ~ /MobileAds#initialize$/ { print $6 }' | sort -u)" \
  "$c: the WildAds.java init CALL is exact"
assert_eq "" "$(calls_in_file "$tmp/$c.tsv" com/example/app/NoWild.java)" "$c: no call from NoWild.java (no wildcard import)"
run "$FT" $c ft.tsv --tsv
assert_true "$c: exact CALL firebase-analytics init FirebaseAnalytics#getInstance in WildAnalytics.java" \
  has_call "$tmp/$c.ft.tsv" firebase-analytics init getInstance com/example/app/WildAnalytics.java
assert_true "$c: import-scoped CALL firebase-analytics event #logEvent in WildAnalytics.java" \
  has_call "$tmp/$c.ft.tsv" firebase-analytics event logEvent com/example/app/WildAnalytics.java
run "$FA" $c txt --entrypoints
entry_points "$tmp/$c.txt" >"$tmp/$c.ep"
assert_true "$c: Entry Points has WildAds.java" grep -q 'com/example/app/WildAds.java:[0-9]' "$tmp/$c.ep"
assert_false "$c: Entry Points has nothing from NoWild.java" grep -q 'NoWild.java' "$tmp/$c.ep"

t_done
