#!/usr/bin/env bash
# t_cli.sh -- the CLI of find-trackers.sh / find-ads.sh on the sdk-audit engine (DESIGN 5.1,
# 5.2, I15, I17, I18): every historical flag of both tools is accepted (rc 0), the new
# options work, option tokens are normalized (dashes dropped, case-insensitive,
# --name:value / --name=value for valued options), `--` ends the options, the last
# positional wins, exit codes 0/1/2 (usage on stdout for -h, on stderr for errors),
# INSTALL_REQUIRED:jq without jq (or with jq 1.5), --sdk outside the tool group, a
# missing engine. Product scripts run with $BASH32 when it is set.
# requires: NS/sdk-audit.sh S/tracker-analysis/scripts/find-trackers.sh S/ad-analysis/scripts/find-ads.sh
# requires: cmd: have_jq16
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
export LC_ALL=C

FT=$S/tracker-analysis/scripts/find-trackers.sh
FA=$S/ad-analysis/scripts/find-ads.sh
mktemp_dir tmp
F=$tmp/fx
bash "$TESTS_DIR/fixtures/pitfalls/make-pitfalls.sh" "$F" >/dev/null || die "make-pitfalls.sh failed"
TRK=$F/p11-firebase-logevent-instance     # jadx layout
ADS=$F/p03-jadx-multiline-manifest        # jadx layout, manifest-only AdMob

# run <out-prefix> <script> [args...]: rc in $RC, stdout/stderr in <out-prefix>.out/.err
run() {
  _o=$1; shift
  run_bash "$@" >"$_o.out" 2>"$_o.err"
  RC=$?
}
expect_rc() { # expect_rc <rc> <message> <script> [args...]
  _want=$1 _msg=$2; shift 2
  run "$tmp/x" "$@"
  assert_eq "$_want" "$RC" "$_msg (rc)"
}

# ---- help -------------------------------------------------------------------------------
for tool in "$FT" "$FA"; do
  tn=$(basename "$tool" .sh)
  for h in -h --help -H -Help --HELP; do
    run "$tmp/h" "$tool" "$h"
    assert_eq 0 "$RC" "$tn $h: rc 0"
    assert_true "$tn $h: usage on stdout" grep -q "^Usage: $tn.sh <input-dir>" "$tmp/h.out"
    assert_eq "" "$(cat "$tmp/h.err")" "$tn $h: nothing on stderr"
  done
done

# ---- every flag of both tools: rc 0 ------------------------------------------------------
for f in --firebase --adjust --appsflyer --mixpanel --amplitude --segment --braze --clevertap --flurry \
         --generic --endpoints --manifest --entrypoints --all --summary --json --tsv --full --no-hints; do
  expect_rc 0 "find-trackers $f" "$FT" "$TRK" "$f"
  case "$f" in --summary|--json|--tsv) ;; *)
    assert_true "find-trackers $f: === Search complete ===" grep -qx '=== Search complete ===' "$tmp/x.out" ;; esac
done
for f in --admob --unity --ironsource --applovin --facebook --vungle --inmobi --chartboost --pangle --mintegral \
         --formats --mediation --consent --manifest --entrypoints --all --summary --json --tsv --full --no-hints; do
  expect_rc 0 "find-ads $f" "$FA" "$ADS" "$f"
  case "$f" in --summary|--json|--tsv) ;; *)
    assert_true "find-ads $f: === Search complete ===" grep -qx '=== Search complete ===' "$tmp/x.out" ;; esac
done
expect_rc 0 "find-trackers --sdk singular" "$FT" "$TRK" --sdk singular
assert_true "find-trackers --sdk singular prints its section even when NOT FOUND" \
  grep -q '^# confidence=NONE status=NOT FOUND' "$tmp/x.out"
expect_rc 0 "find-ads --sdk google-ump-consent --sdk kidoz" "$FA" "$ADS" --sdk google-ump-consent --sdk kidoz
assert_true "find-ads two --sdk: Kidoz section" grep -q '^==== Kidoz — Identity ====$' "$tmp/x.out"

# ---- output formats ------------------------------------------------------------------------
run "$tmp/j" "$FT" "$TRK" --json
assert_eq 0 "$RC" "find-trackers --json: rc 0"
assert_eq 2 "$(jq -r '.schema_version' "$tmp/j.out")" "--json: schema_version 2"
assert_eq "find-trackers" "$(jq -r '.tool' "$tmp/j.out")" "--json: tool"
assert_eq "jadx" "$(jq -r '.input.layout' "$tmp/j.out")" "--json: input.layout"
assert_eq "HIGH" "$(jq -r '.trackers[] | select(.sdk_id == "firebase-analytics") | .confidence' "$tmp/j.out")" "--json: firebase-analytics HIGH"
assert_eq "Firebase" "$(jq -r '.trackers[] | select(.sdk_id == "firebase-analytics") | .sdk' "$tmp/j.out")" "--json: legacy label as sdk"
assert_eq "true" "$(jq -r '[.entry_points[] | select(.path | endswith("WithImport.java"))] | length > 0' "$tmp/j.out")" "--json: entry point from WithImport.java"
run "$tmp/ja" "$FA" "$ADS" --json
assert_eq "true" "$(jq -r 'has("ad_sdks") and has("consent_sdks") and has("mediation")' "$tmp/ja.out")" "find-ads --json: ad_sdks, consent_sdks, mediation"
run "$tmp/s" "$FT" "$TRK" --summary
assert_true "--summary: title" grep -qx '=== Tracker Detection Summary ===' "$tmp/s.out"
assert_true "--summary: header row" grep -q '^SDK                    | SDK_ID               | FILES | MANIF | ENDP | APPREF | CONF   | STATUS    | NEUTRALIZE$' "$tmp/s.out"
assert_eq 9 "$(grep -cE '^(Firebase|Adjust|AppsFlyer|Mixpanel|Amplitude|Segment|Braze|CleverTap|Flurry) +\|' "$tmp/s.out")" "--summary: the 9 legacy rows"
run "$tmp/sa" "$FA" "$ADS" --summary
assert_true "find-ads --summary: title" grep -qx '=== Ad SDK Detection Summary ===' "$tmp/sa.out"
assert_true "find-ads --summary: Consent framework line" grep -q '^Consent framework: ' "$tmp/sa.out"
run "$tmp/t" "$FT" "$TRK" --tsv
assert_true "--tsv: header" grep -q "$(printf '^#sdk-audit\t2\ttool=find-trackers\tlayout=jadx$')" "$tmp/t.out"
ntrk=$(run_bash "$FT" --list-sdks 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
assert_eq "$ntrk" "$(grep -c "$(printf '^SDK\t')" "$tmp/t.out")" "--tsv: one SDK row per tracker entry (NONE included)"
# precedence json > tsv > summary; filters ignored with a note
run "$tmp/p1" "$FT" "$TRK" --summary --tsv
assert_true "--summary --tsv -> tsv" grep -q '^#sdk-audit' "$tmp/p1.out"
run "$tmp/p2" "$FT" "$TRK" --tsv --json --summary
assert_eq 2 "$(jq -r '.schema_version' "$tmp/p2.out" 2>/dev/null)" "--tsv --json --summary -> json"
run "$tmp/p3" "$FT" "$TRK" --summary --firebase
assert_true "--summary with a filter: note on stderr" grep -q 'filters are ignored' "$tmp/p3.err"
cmp -s "$tmp/s.out" "$tmp/p3.out"; assert_eq 0 $? "--summary --firebase == --summary"

# ---- --list-sdks ----------------------------------------------------------------------------
run "$tmp/l" "$FT" --list-sdks
assert_eq 0 "$RC" "find-trackers --list-sdks without input: rc 0"
assert_eq "$(printf 'sdk_id\tcategory\tlegacy_flag\tneutralizable\tpackages\taudit_only_packages')" "$(head -n 1 "$tmp/l.out")" "--list-sdks header"
assert_true "--list-sdks: segment --segment detection-only" grep -q "$(printf '^segment\tanalytics\t--segment\tno\tcom.segment.analytics\t-$')" "$tmp/l.out"
assert_false "--list-sdks (trackers): no ads entry" grep -q "^google-admob" "$tmp/l.out"
run "$tmp/la" "$FA" --list-sdks
assert_true "find-ads --list-sdks: google-ump-consent (consent group)" grep -q "^google-ump-consent" "$tmp/la.out"
# .packages (neutralized) and detection.extra_packages (audit only) stay in separate columns
assert_eq "com.bytedance.sdk.openadsdk" "$(awk -F '\t' '$1 == "pangle" { print $5 }' "$tmp/la.out")" "find-ads --list-sdks: pangle packages = .packages only"
assert_true "find-ads --list-sdks: pangle audit_only_packages has com.pgl.ssdk" awk -F '\t' '$1 == "pangle" && $6 ~ /(^| )com\.pgl\.ssdk( |$)/ { f = 1 } END { exit !f }' "$tmp/la.out"

# ---- option normalization -----------------------------------------------------------------
run "$tmp/n0" "$FA" "$ADS" --admob
for v in -admob -Admob --ADMOB ---admob; do
  run "$tmp/n1" "$FA" "$ADS" "$v"
  assert_eq 0 "$RC" "find-ads $v: rc 0"
  cmp -s "$tmp/n0.out" "$tmp/n1.out"; assert_eq 0 $? "find-ads $v == --admob"
done
run "$tmp/m0" "$FA" "$F/p03-jadx-multiline-manifest/sources" --tsv --manifest-path "$ADS/resources/AndroidManifest.xml"
for form in "-ManifestPath|$ADS/resources/AndroidManifest.xml" "--manifest-path=$ADS/resources/AndroidManifest.xml" "--MANIFEST-PATH:$ADS/resources/AndroidManifest.xml"; do
  case "$form" in *"|"*) run "$tmp/m1" "$FA" "$F/p03-jadx-multiline-manifest/sources" --tsv "${form%%|*}" "${form#*|}" ;;
                  *) run "$tmp/m1" "$FA" "$F/p03-jadx-multiline-manifest/sources" --tsv "$form" ;; esac
  assert_eq 0 "$RC" "find-ads ${form%%|*}: rc 0"
  cmp -s "$tmp/m0.out" "$tmp/m1.out"; assert_eq 0 $? "find-ads ${form%%[:=|]*}: same as --manifest-path"
done
run "$tmp/k1" "$FT" "$TRK" --sdk flurry
for form in --sdk:flurry --sdk=flurry -SDK:flurry; do
  run "$tmp/k2" "$FT" "$TRK" "$form"
  cmp -s "$tmp/k1.out" "$tmp/k2.out"; assert_eq 0 $? "find-trackers $form == --sdk flurry"
done
expect_rc 0 "--registry DIR" "$FT" "$TRK" --registry "$REG" --tsv
expect_rc 0 "--registry=DIR" "$FT" "$TRK" "--registry=$REG" --tsv

# ---- -- and the last positional --------------------------------------------------------------
mkdir -p "$tmp/-dash"; cp -R "$TRK/." "$tmp/-dash/"
( cd "$tmp" && run_bash "$FT" --tsv -- -dash >"$tmp/dd.out" 2>"$tmp/dd.err" ); assert_eq 0 $? "-- then a directory named -dash: rc 0"
expect_rc 1 "a directory named -dash without --: unknown option" "$FT" --tsv "-dash"
# a relative path shaped like var=value must reach awk as a file, not as an assignment
mkdir -p "$tmp/a=b"; cp -R "$ADS/." "$tmp/a=b/"; cp "$ADS/resources/AndroidManifest.xml" "$tmp/m=x.xml"
( cd "$tmp" && run_bash "$FA" --tsv "$tmp/a=b" </dev/null >"$tmp/eq0.out" 2>/dev/null )
( cd "$tmp" && run_bash "$FA" --tsv a=b </dev/null >"$tmp/eq1.out" 2>"$tmp/eq1.err" ); assert_eq 0 $? "relative directory a=b: rc 0"
cmp -s "$tmp/eq0.out" "$tmp/eq1.out"; assert_eq 0 $? "relative directory a=b: same --tsv as the absolute path"
assert_true "relative directory a=b: manifest evidence read" grep -q '^EV	google-admob	manifest' "$tmp/eq1.out"
( cd "$tmp" && run_bash "$FA" --tsv "$tmp/a=b/sources" --manifest-path m=x.xml </dev/null >"$tmp/eq2.out" 2>/dev/null ); assert_eq 0 $? "--manifest-path m=x.xml: rc 0"
sed 1d "$tmp/eq0.out" >"$tmp/eq0.body"; sed 1d "$tmp/eq2.out" >"$tmp/eq2.body"   # line 1 names the layout
cmp -s "$tmp/eq0.body" "$tmp/eq2.body"; assert_eq 0 $? "--manifest-path m=x.xml: same --tsv rows as the found manifest"
expect_rc 0 "last positional wins" "$FT" /nonexistent/dir "$TRK" --tsv

# ---- errors -----------------------------------------------------------------------------------
for tool in "$FT" "$FA"; do
  tn=$(basename "$tool" .sh)
  run "$tmp/e" "$tool" "$TRK" --bogus
  assert_eq 1 "$RC" "$tn --bogus: rc 1"
  assert_eq "" "$(cat "$tmp/e.out")" "$tn --bogus: nothing on stdout"
  assert_true "$tn --bogus: error + usage on stderr" grep -q "^Usage: $tn.sh" "$tmp/e.err"
  expect_rc 1 "$tn missing directory" "$tool" /nonexistent/dir
  assert_true "$tn missing directory: message" grep -q 'Directory not found: /nonexistent/dir' "$tmp/x.err"
  expect_rc 1 "$tn no input" "$tool" --tsv
  expect_rc 1 "$tn --sdk without value" "$tool" "$TRK" --sdk
  expect_rc 1 "$tn --all:1 (value on a flag)" "$tool" "$TRK" --all:1
  expect_rc 1 "$tn --sdk nope" "$tool" "$TRK" --sdk nope
  expect_rc 1 "$tn --manifest-path missing file" "$tool" "$TRK" --manifest-path /nonexistent.xml
done
expect_rc 1 "find-ads --sdk adjust" "$FA" "$ADS" --sdk adjust
assert_true "find-ads --sdk adjust: message" grep -q "Error: 'adjust' is a find-trackers SDK" "$tmp/x.err"
expect_rc 1 "find-trackers --sdk google-admob" "$FT" "$TRK" --sdk google-admob
assert_true "find-trackers --sdk google-admob: message" grep -q "Error: 'google-admob' is a find-ads SDK" "$tmp/x.err"
expect_rc 1 "find-trackers --admob (other tool's flag)" "$FT" "$TRK" --admob
expect_rc 1 "find-ads --generic (other tool's aspect)" "$FA" "$ADS" --generic
expect_rc 1 "--registry with a missing directory" "$FT" "$TRK" --registry /nonexistent/reg
SDK_AUDIT_ENGINE=/nonexistent/sdk-audit.sh run "$tmp/ne" "$FA" "$ADS"
assert_eq 1 "$RC" "missing engine: rc 1"
assert_true "missing engine: message" grep -q 'Error: sdk-audit engine not found at /nonexistent/sdk-audit.sh (install the whole android-reverse-engineering plugin)' "$tmp/ne.err"

# ---- jq missing or too old: exit 2 + INSTALL_REQUIRED:jq ----------------------------------------
for shim in nojq jq15; do
  for tool in "$FT" "$FA"; do
    with_shim "$shim" "${BASH32:-bash}" "$tool" "$TRK" >"$tmp/q.out" 2>"$tmp/q.err"
    assert_eq 2 "$?" "$shim $(basename "$tool"): rc 2"
    assert_eq "INSTALL_REQUIRED:jq" "$(cat "$tmp/q.out")" "$shim $(basename "$tool"): INSTALL_REQUIRED:jq on stdout"
    assert_true "$shim $(basename "$tool"): install command on stderr" grep -q 'install-dep.sh jq' "$tmp/q.err"
  done
done
with_shim nojq "${BASH32:-bash}" "$FT" -h >/dev/null 2>&1; assert_eq 0 $? "nojq -h: rc 0 (help needs no jq)"

# ---- manifest: only declaring tags are evidence (DESIGN 5.4 step 6) -----------------------------
# <queries><package> names another app (package visibility), not an SDK in the APK; the same
# for uses-feature, uses-library, category, property and application. A queries <action> is
# kept (AppsFlyer's INSTALL_PROVIDER is a manifest_names entry).
Q=$tmp/qtree; mkdir -p "$Q/com/example"
printf '%s\n' 'package com.example; class A {}' >"$Q/com/example/A.java"
cat >"$Q/AndroidManifest.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.example.q">
    <uses-feature android:name="com.facebook.feature"/>
    <queries>
        <package android:name="com.facebook.katana"/>
        <intent>
            <action android:name="com.appsflyer.referrer.INSTALL_PROVIDER"/>
            <category android:name="com.facebook.category"/>
        </intent>
    </queries>
    <application android:name="com.facebook.FacebookApp">
        <uses-library android:name="com.facebook.lib" android:required="false"/>
        <property android:name="com.facebook.prop" android:value="x"/>
        <activity android:name=".Main"/>
    </application>
</manifest>
EOF
run "$tmp/qt" "$FT" "$Q" --tsv
assert_eq 0 "$RC" "queries manifest: rc 0"
assert_true "queries manifest: facebook NONE" grep -q "$(printf '^SDK\tfacebook\tsocial\tNONE\t')" "$tmp/qt.out"
assert_false "queries manifest: no facebook manifest evidence" grep -q "$(printf '^EV\tfacebook\tmanifest\t')" "$tmp/qt.out"
assert_true "queries manifest: queries action kept for appsflyer" \
  grep -q "$(printf '^EV\tappsflyer\tmanifest\taction\tcom.appsflyer.referrer.INSTALL_PROVIDER$')" "$tmp/qt.out"

t_done
