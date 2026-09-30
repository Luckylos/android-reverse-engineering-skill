#!/usr/bin/env bash
# t_scan_filter.sh -- invariant I4 (+ I23): an entry without `targets` (detection-only)
# changes nothing in registry-scan.py: no MATCHED line, same exit code, no manifest line,
# same UNKNOWN_PACKAGE list. For each fixture entry of tests/fixtures/scan-filter
# (regA1: plain detection-only; regA2: also carries manifest_components, which the
# schema forbids) registry-scan runs on synthetic apktool trees with the registry under
# test and with the same registry plus that entry: stdout, stderr, exit code and the
# three output files must be byte-identical (depth 1/3 x ads/trackers/all).
# Control: the registry-scan.py of $ARE_BASE_COMMIT (before the guard) DOES match the
# entry on the same tree, so the fixture really exercises the guard.
# requires: cmd: command -v python3 >/dev/null
# requires: cmd: git -C "$REPO" cat-file -e "$ARE_BASE_COMMIT^{commit}"
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
export LC_ALL=C

SCAN=$NS/registry-scan.py
FIX=$TESTS_DIR/fixtures/scan-filter
[ -f "$SCAN" ] || die "registry-scan.py not found: $SCAN"
mktemp_dir tmp

# ---- synthetic trees ------------------------------------------------------------------
smali_class() { # smali_class <root> <pkg/path/Class>
  mkdir -p "$1/smali/$(dirname "$2")"
  printf '.class public L%s;\n.super Ljava/lang/Object;\n\n.method public static init()V\n    .locals 0\n    return-void\n.end method\n' \
    "$2" >"$1/smali/$2.smali"
}
manifest() { # manifest <root> <extra component lines>
  mkdir -p "$1"
  printf '<?xml version="1.0" encoding="utf-8" standalone="no"?><manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.example.scanfilter">\n  <application>\n%s  </application>\n</manifest>\n' \
    "$2" >"$1/AndroidManifest.xml"
}
stencyl_classes() { # >= MIN_CLASSES_FOR_UNKNOWN (10) classes, so the package shows up as UNKNOWN
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do smali_class "$1" "com/stencyl/extension/Ext$i"; done
  smali_class "$1" com/stencyl/extension/FooService
}
# mixed: a real registry SDK (Unity Ads, targets + manifest components) + the stencyl package
T1=$tmp/tree-mixed
manifest "$T1" '    <service android:name="com.stencyl.extension.FooService"/>
    <activity android:name="com.unity3d.ads.adunit.AdUnitActivity"/>
'
smali_class "$T1" com/example/scanfilter/MainActivity
smali_class "$T1" com/unity3d/ads/UnityAds
smali_class "$T1" com/unity3d/services/UnityServices
stencyl_classes "$T1"
# only: nothing but the detection-only package (no match at all -> exit 2)
T2=$tmp/tree-only
manifest "$T2" '    <service android:name="com.stencyl.extension.FooService"/>
'
smali_class "$T2" com/example/scanfilter/MainActivity
stencyl_classes "$T2"
trees="$T1 $T2"
# synth48 of the registry under test (every entry matches) + the stencyl package
if have_jq16; then
  T3=$tmp/tree-synth
  if bash "$TESTS_DIR/fixtures/make-synth48.sh" "$REG" "$T3" 2>"$tmp/synth.err"; then
    stencyl_classes "$T3"; trees="$trees $T3"
  else
    fail_check "make-synth48.sh failed on $REG: $(head -n 3 "$tmp/synth.err")"
  fi
fi

# ---- runs -------------------------------------------------------------------------------
# scan <script> <registry> <tree> <depth> <cat> <outdir>: registry-scan with the
# output dir and tree paths masked, as in tests/golden/capture.sh
scan() {
  mkdir -p "$6"
  python3 "$1" "$3" --registry "$2" --depth "$4" --category "$5" --output-dir "$6" \
    >"$6/stdout" 2>"$6/stderr"
  echo "$?" >"$6/exit"
  sed -i "s#$6#<OUT>#g; s#$3#<TREE>#g" "$6/stdout" "$6/stderr"
}
same_run() { # same_run <label> <dir-a> <dir-b>
  for f in stdout stderr exit registry-targets.txt registry-manifest.txt registry-report.json; do
    assert_files_eq "$2/$f" "$3/$f" "$1: $f identical"
  done
}

REG0=$tmp/reg-base
mkdir -p "$REG0"
cp "$REG"/*.json "$REG0/"
for variant in regA1 regA2; do
  entry=$FIX/$variant/stencyl-ext.json
  [ -f "$entry" ] || die "fixture missing: $entry"
  assert_eq no "$(python3 -c 'import json,sys; print("yes" if "targets" in json.load(open(sys.argv[1])) else "no")' "$entry" 2>&1)" \
    "$variant: fixture entry has no targets"
  regv=$tmp/reg-$variant
  mkdir -p "$regv"
  cp "$REG"/*.json "$regv/"
  cp "$entry" "$regv/"
  for tree in $trees; do
    tn=$(basename "$tree")
    for depth in 1 3; do
      for cat in ads trackers all; do
        a=$tmp/out/$variant/$tn/d$depth-$cat/base
        b=$tmp/out/$variant/$tn/d$depth-$cat/with
        scan "$SCAN" "$REG0" "$tree" "$depth" "$cat" "$a"
        scan "$SCAN" "$regv" "$tree" "$depth" "$cat" "$b"
        same_run "$variant $tn d$depth-$cat" "$a" "$b"
        assert_false "$variant $tn d$depth-$cat: no MATCHED:stencyl-ext" grep -q '^MATCHED:stencyl-ext:' "$b/stdout"
        assert_false "$variant $tn d$depth-$cat: no FooService manifest line" \
          grep -q 'com\.stencyl\.extension\.FooService' "$b/registry-manifest.txt"
      done
    done
  done
  # the detection-only package is reported as unknown, exactly as without the entry
  assert_true "$variant tree-mixed: com/stencyl/extension stays UNKNOWN_PACKAGE" \
    grep -q '^UNKNOWN_PACKAGE:com/stencyl/extension:' "$tmp/out/$variant/tree-mixed/d1-all/with/stdout"
  assert_eq 2 "$(cat "$tmp/out/$variant/tree-only/d1-all/with/exit")" \
    "$variant tree-only: no match -> exit 2 (not 0)"
done

# ---- control: the scanner before the guard matches the entry ----------------------------
git -C "$REPO" show "$ARE_BASE_COMMIT:plugins/android-reverse-engineering/skills/sdk-neutralizer/scripts/registry-scan.py" \
  >"$tmp/registry-scan.base.py" || die "cannot read registry-scan.py of $ARE_BASE_COMMIT"
c=$tmp/out/control
scan "$tmp/registry-scan.base.py" "$tmp/reg-regA2" "$T2" 1 all "$c"
assert_true "control: pre-guard scanner reports MATCHED:stencyl-ext" grep -q '^MATCHED:stencyl-ext:' "$c/stdout"
assert_eq 0 "$(cat "$c/exit")" "control: pre-guard scanner exits 0 (A1 experiment)"
assert_true "control: pre-guard scanner writes the FooService manifest line (A2 experiment)" \
  grep -q '^com\.stencyl\.extension\.FooService|' "$c/registry-manifest.txt"

t_done
