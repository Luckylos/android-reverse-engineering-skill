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
#   - '.', 'sources/.' and '..' naming <out>/sources are jadx-sources (basename of the full
#     path, DEVIATIONS 9.5);
#   - a tree without AndroidManifest.xml says so, and --manifest-path fixes it.
# PowerShell side (DESIGN 5.3, 10 row 9; when NS/sdk-audit.ps1 exists and PowerShell 5.1 is
# reachable, ARE_PS): find-trackers.ps1 / find-ads.ps1 run with -File on the same five layouts
# through the \\wsl.localhost UNC path give --tsv and text equal to the same expected files
# (input path -> <IN>, backslash -> /, CR dropped) and the right [INFO] layout line; a copy of
# the jadx layout on a Windows drive (C:\...\Temp) gives the expected find-ads output too.
# Run once, not once per awk shim (the PowerShell engine uses no awk). Without PowerShell the
# ps1 part prints a note; t_parity (SKIP without PowerShell) is the strict gate.
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

# '.' (or 'sources/.') naming <out>/sources is jadx-sources too: the rule takes the basename
# of the full path, as the ps1 twin does (t_parity checks the two twins on '.')
for spec in "jadx/sources	." "jadx	sources/." "jadx/sources/com	.."; do
  cwd=${spec%%"$(printf '\t')"*} arg=${spec#*"$(printf '\t')"}
  (cd "$F/$cwd" && run_bash "$FA" "$arg" --tsv) >"$tmp/dot.tsv" 2>"$tmp/dot.err"
  assert_eq 0 "$?" "'$arg' from $cwd: rc 0"
  assert_true "'$arg' from $cwd: [INFO] layout: jadx-sources" grep -qx '\[INFO\] layout: jadx-sources' "$tmp/dot.err"
  assert_files_eq "$tmp/jadx-sources.find-ads.tsv0" "$tmp/dot.tsv" "'$arg' from $cwd: --tsv == jadx-sources"
done

# tree without a manifest
rm "$F/tree/AndroidManifest.xml"
run_bash "$FA" "$F/tree" --tsv >"$tmp/nm.tsv" 2>"$tmp/nm.err"
assert_eq 0 "$?" "tree without manifest: rc 0"
assert_true "tree without manifest: says so" grep -q '# manifest: not found (use --manifest-path)' "$tmp/nm.err"
assert_eq "" "$(awk -F '\t' '$1 == "EV" && $3 == "manifest"' "$tmp/nm.tsv")" "tree without manifest: no manifest evidence"
run_bash "$FA" "$F/tree" --tsv --manifest-path "$F/jadx/resources/AndroidManifest.xml" >"$tmp/mp.tsv" 2>/dev/null
assert_files_eq "$tmp/tree.find-ads.tsv0" "$tmp/mp.tsv" "tree + --manifest-path == tree with its manifest"

# ---- PowerShell twins ------------------------------------------------------------------------
FTP=$S/tracker-analysis/scripts/find-trackers.ps1
FAP=$S/ad-analysis/scripts/find-ads.ps1
if [ ! -f "$NS/sdk-audit.ps1" ]; then
  echo "note: sdk-audit.ps1 not present: ps1 layouts not checked"
elif ! have_ps || ! command -v wslpath >/dev/null 2>&1; then
  echo "note: PowerShell not available (ARE_PS=$ARE_PS): ps1 layouts not checked"
elif [ -n "${ARE_AWK_SHIM:-}" ] && [ "$ARE_AWK_SHIM" != "$(awk_shims | head -n 1)" ]; then
  echo "note: ps1 layouts checked in the $(awk_shims | head -n 1) run only"
else
  PSH=$TESTS_DIR/parity/ps.sh
  FP=$tmp/fxp
  bash "$TESTS_DIR/fixtures/make-layouts.sh" "$FP" >/dev/null || die "make-layouts.sh failed"
  wtmp=""
  for c in "${ARE_WINTMP:-}" /mnt/c/Users/*/AppData/Local/Temp /mnt/c/Windows/Temp; do
    [ -n "$c" ] && [ -d "$c" ] && [ -w "$c" ] && { wtmp=$c; break; }
  done
  # psjob <name> <win-input> <script> [args...]: background -File run; outputs in $tmp/ps.<name>.*
  psjob() {
    _n=$1 _w=$2 _s=$3; shift 3
    ( bash "$PSH" "$_s" "$_w" "$@" </dev/null >"$tmp/ps.$_n.out" 2>"$tmp/ps.$_n.err"; echo $? >"$tmp/ps.$_n.rc" ) &
  }
  k=0
  while IFS="$(printf '\t')" read -r name dir; do
    for tool in "$FTP" "$FAP"; do
      tn=$(basename "$tool" .ps1)
      psjob "$name.$tn.tsv" "$(wslpath -w "$FP/$dir")" "$tool" --tsv
      psjob "$name.$tn.txt" "$(wslpath -w "$FP/$dir")" "$tool"
      k=$((k + 2)); [ $((k % 4)) = 0 ] && wait
    done
  done <<LAYOUTS_EOF
$LAYOUTS
LAYOUTS_EOF
  if [ -n "$wtmp" ]; then
    wdir=$(mktemp -d "$wtmp/are-lay.XXXXXX")
    _T_TMPS="$_T_TMPS
$wdir"
    cp -R "$FP/jadx" "$wdir/jadx"
    psjob "drive.tsv" "$(wslpath -w "$wdir/jadx")" "$FAP" --tsv
    psjob "drive.txt" "$(wslpath -w "$wdir/jadx")" "$FAP"
  else
    fail_check "no writable Windows temp dir: drive-letter input not checked"
  fi
  wait
  while IFS="$(printf '\t')" read -r name dir; do
    win=$(wslpath -w "$FP/$dir")
    for tn in find-trackers find-ads; do
      for kind in tsv txt; do
        n=$name.$tn.$kind
        assert_eq 0 "$(cat "$tmp/ps.$n.rc")" "ps1 $name $tn $kind: rc 0"
        normalize "$win" <"$tmp/ps.$n.out" >"$tmp/ps.$n.norm"
        assert_files_eq "$EXP/$name.$tn.$kind" "$tmp/ps.$n.norm" "ps1 $name $tn $kind == expected/layouts/$name.$tn.$kind"
      done
      assert_eq "[INFO] layout: $name" "$(tr -d '\r' <"$tmp/ps.$name.$tn.tsv.err" | grep '^\[INFO\] layout: ')" "ps1 $name $tn: [INFO] layout: $name"
    done
  done <<LAYOUTS_EOF
$LAYOUTS
LAYOUTS_EOF
  if [ -n "$wtmp" ]; then
    win=$(wslpath -w "$wdir/jadx")
    for kind in tsv txt; do
      assert_eq 0 "$(cat "$tmp/ps.drive.$kind.rc")" "ps1 drive-letter input ($win) $kind: rc 0"
      normalize "$win" <"$tmp/ps.drive.$kind.out" >"$tmp/ps.drive.$kind.norm"
      assert_files_eq "$EXP/jadx.find-ads.$kind" "$tmp/ps.drive.$kind.norm" "ps1 drive-letter input: jadx find-ads $kind == expected"
    done
  fi
fi

t_done
