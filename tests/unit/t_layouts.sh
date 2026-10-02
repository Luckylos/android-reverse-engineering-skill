#!/usr/bin/env bash
# t_layouts.sh -- input resolution of find-trackers / find-ads (DESIGN 5.3, 5.5, I16, I22)
# on the five layouts of tests/fixtures/make-layouts.sh: apktool, jadx, jadx-sources,
# jadx-xapk, tree.
#   - the layout, code roots and manifest are detected (stderr [INFO] lines), the jadx-xapk
#     manifest is the base split's (no split= attribute), smali_assets is not code;
#   - --tsv is identical on the four Java layouts once the header and the path of each
#     CALL row (relative to the input) are reduced to the path under the code root;
#   - text and --tsv outputs of every layout equal the committed expected files
#     (tests/fixtures/expected/layouts/<layout>.<tool>.{txt,tsv}; the input path is
#     written <IN>); ARE_UPDATE_EXPECTED=1 rewrites them;
#   - a tree without AndroidManifest.xml says so, and --manifest-path fixes it.
# The PowerShell side of this test comes with sdk-audit.ps1 (DESIGN 10, commit 9).
# requires: NS/sdk-audit.sh S/tracker-analysis/scripts/find-trackers.sh S/ad-analysis/scripts/find-ads.sh
# requires: cmd: have_jq16
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
export LC_ALL=C

FT=$S/tracker-analysis/scripts/find-trackers.sh
FA=$S/ad-analysis/scripts/find-ads.sh
EXP=$TESTS_DIR/fixtures/expected/layouts
mktemp_dir tmp
F=$tmp/fx
bash "$TESTS_DIR/fixtures/make-layouts.sh" "$F" >/dev/null || die "make-layouts.sh failed"
[ "${ARE_UPDATE_EXPECTED:-0}" = 1 ] && mkdir -p "$EXP"

# layout name <TAB> input dir (relative to $F)
LAYOUTS="apktool	apktool
jadx	jadx
jadx-sources	jadx/sources
jadx-xapk	xapk
tree	tree"

check_expected() { # check_expected <file> <expected-name>
  if [ "${ARE_UPDATE_EXPECTED:-0}" = 1 ]; then cp "$1" "$EXP/$2"; return 0; fi
  if [ -f "$EXP/$2" ]; then assert_files_eq "$EXP/$2" "$1" "output == expected/layouts/$2"
  else _T_CHECKS=$((_T_CHECKS + 1)); fail_check "missing expected file expected/layouts/$2"; fi
}

while IFS="$(printf '\t')" read -r name dir; do
  in=$F/$dir
  for tool in "$FT" "$FA"; do
    tn=$(basename "$tool" .sh)
    run_bash "$tool" "$in" --tsv >"$tmp/$name.$tn.tsv0" 2>"$tmp/$name.$tn.err"
    assert_eq 0 "$?" "$name $tn --tsv: rc 0"
    assert_true "$name $tn: [INFO] layout: $name" grep -qx "\[INFO\] layout: $name" "$tmp/$name.$tn.err"
    normalize "$in" <"$tmp/$name.$tn.tsv0" >"$tmp/$name.$tn.tsv"
    check_expected "$tmp/$name.$tn.tsv" "$name.$tn.tsv"
    run_bash "$tool" "$in" >"$tmp/$name.$tn.txt0" 2>/dev/null
    assert_eq 0 "$?" "$name $tn text: rc 0"
    normalize "$in" <"$tmp/$name.$tn.txt0" >"$tmp/$name.$tn.txt"
    check_expected "$tmp/$name.$tn.txt" "$name.$tn.txt"
    # the four Java layouts: same rows once CALL paths are taken under the code root
    if [ "$name" != apktool ]; then
      awk -F '\t' 'BEGIN { OFS = "\t" } NR == 1 { next }
        $1 == "CALL" { sub(/^.*sources\//, "", $5) } { print }' "$tmp/$name.$tn.tsv0" >"$tmp/$name.$tn.core"
    fi
  done
done <<EOF
$LAYOUTS
EOF

for tn in find-trackers find-ads; do
  for name in jadx-sources jadx-xapk tree; do
    assert_files_eq "$tmp/jadx.$tn.core" "$tmp/$name.$tn.core" "$tn --tsv: $name == jadx (header and path prefix aside)"
  done
done

# detection details
assert_true "jadx-xapk: two code roots" [ "$(grep -c '^\[INFO\] code root: ' "$tmp/jadx-xapk.find-ads.err")" = 2 ]
assert_true "jadx-xapk: base split manifest" grep -qx "\[INFO\] manifest: $F/xapk/com.example.app/resources/AndroidManifest.xml" "$tmp/jadx-xapk.find-ads.err"
assert_true "jadx-sources: manifest next to sources/" grep -qx "\[INFO\] manifest: $F/jadx/sources/../resources/AndroidManifest.xml" "$tmp/jadx-sources.find-ads.err"
assert_true "apktool: smali and smali_classes2 are code roots" [ "$(grep -c '^\[INFO\] code root: ' "$tmp/apktool.find-ads.err")" = 2 ]
assert_false "apktool: smali_assets is not a code root" grep -q 'smali_assets' "$tmp/apktool.find-ads.err"
assert_eq "NONE" "$(awk -F '\t' '$1 == "SDK" && $2 == "mixpanel" { print $4 }' "$tmp/apktool.find-trackers.tsv")" "apktool: a class in smali_assets is not evidence (mixpanel NONE)"
for name in apktool jadx jadx-sources jadx-xapk tree; do
  assert_eq "HIGH" "$(awk -F '\t' '$1 == "SDK" && $2 == "flurry" { print $4 }' "$tmp/$name.find-trackers.tsv")" "$name: flurry HIGH"
  assert_eq "HIGH" "$(awk -F '\t' '$1 == "SDK" && $2 == "unity-ads" { print $4 }' "$tmp/$name.find-ads.tsv")" "$name: unity-ads HIGH"
  assert_eq "NONE" "$(awk -F '\t' '$1 == "SDK" && $2 == "facebook" { print $4 }' "$tmp/$name.find-trackers.tsv")" "$name: SoLoader alone is not facebook"
  assert_true "$name: manifest evidence of the multi-line / one-line manifest" \
    grep -q "$(printf '^EV\tgoogle-admob\tmanifest\tactivity\tcom.google.android.gms.ads.AdActivity$')" "$tmp/$name.find-ads.tsv"
done

# tree without a manifest
rm "$F/tree/AndroidManifest.xml"
run_bash "$FA" "$F/tree" --tsv >"$tmp/nm.tsv" 2>"$tmp/nm.err"
assert_eq 0 "$?" "tree without manifest: rc 0"
assert_true "tree without manifest: says so" grep -q '# manifest: not found (use --manifest-path)' "$tmp/nm.err"
assert_eq "" "$(awk -F '\t' '$1 == "EV" && $3 == "manifest"' "$tmp/nm.tsv")" "tree without manifest: no manifest evidence"
run_bash "$FA" "$F/tree" --tsv --manifest-path "$F/jadx/resources/AndroidManifest.xml" >"$tmp/mp.tsv" 2>/dev/null
assert_files_eq "$tmp/tree.find-ads.tsv0" "$tmp/mp.tsv" "tree + --manifest-path == tree with its manifest"

t_done
