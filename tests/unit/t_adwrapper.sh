#!/usr/bin/env bash
# t_adwrapper.sh -- detect-adwrapper.sh reads the registry only through registry-query
# `packages` (DESIGN 6; invariants I12, I13, I14, I19):
#   - fixture (tests/fixtures/make-adwrapper-fixture.sh): the ADWRAPPER_* lines match
#     tests/fixtures/expected/adwrapper-fixture.txt (tv.superawesome.lib, yads.core.impl and
#     backtraceio.library.sub gone: the .packages reader sees them), with --registry and
#     with the default resolution, and identically with no jq (tests/shims/nojq) and with
#     an old jq (tests/shims/jq15: the awk fallback);
#   - I13: exit 0 + ADWRAPPER_SUMMARY with a malformed entry (regD: invalid JSON), an entry
#     without sdk_id (regE) or an unreadable entry file (regP: chmod 000; the same per-file
#     WARN and output in the jq / nojq / jq15 modes), and with an unreadable registry
#     (missing / no entry) -> the WARN
#     "[WARN] registry unreadable: registry exclusions skipped" and the static tables only;
#   - --dump-exclusions: sorted unique EXCL, INHOUSE map = the in_house_wrapper rows of
#     registry-query packages in order (I12), identical in the jq / nojq / jq15 modes;
#   - I19: decode-apk.sh (with a fake apktool that "decodes" the fixture) still exits 0 and
#     prints the same ADWRAPPER_* lines, also with no jq and with a broken registry;
#   - CLI: -h rc 0 (mentions --dump-exclusions), --bogus rc 1, no directory rc 1.
# regD / regE are rebuilt from the real registry (+ the scratch files' exact content); the
# scratch copies under $ARE_WORKSPACE/registry-unification/scratch/contract/tol are used
# too when present. run.sh runs this test once per awk shim.
# awk-matrix
# requires: NS/registry-query.sh NS/detect-adwrapper.sh NS/decode-apk.sh
# requires: cmd: grep -q -- --dump-exclusions "$NS/detect-adwrapper.sh"
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
export LC_ALL=C

DW=$NS/detect-adwrapper.sh
EXPECTED=$TESTS_DIR/fixtures/expected/adwrapper-fixture.txt
WARN_LINE='[WARN] registry unreadable: registry exclusions skipped'
mktemp_dir tmp
echo "awk: ${ARE_AWK_SHIM:-default awk ($(command -v awk))}; jq: $(have_jq16 && echo '>= 1.6' || echo 'missing/old')"

FIX=$tmp/fixture
bash "$TESTS_DIR/fixtures/make-adwrapper-fixture.sh" "$FIX" >/dev/null || die "make-adwrapper-fixture.sh failed"
adw_lines() { grep '^ADWRAPPER_' "$1" || true; }

# run_dw <name> [shim] -- <args...>: run detect-adwrapper.sh, keep out/err/rc
run_dw() {
  _n=$1 _shim=$2; shift 3
  if [ "$_shim" = - ]; then run_bash "$DW" "$@" >"$tmp/$_n.out" 2>"$tmp/$_n.err"
  else with_shim "$_shim" run_bash "$DW" "$@" >"$tmp/$_n.out" 2>"$tmp/$_n.err"; fi
  echo "$?" >"$tmp/$_n.rc"
  adw_lines "$tmp/$_n.out" >"$tmp/$_n.adw"
}
check_ok() { # check_ok <name> <message>: exit 0 and exactly one ADWRAPPER_SUMMARY:none|candidate
  assert_eq 0 "$(cat "$tmp/$1.rc")" "[$1] exit 0 ($2)"
  assert_eq 1 "$(grep -cE '^ADWRAPPER_SUMMARY:(none|candidate)$' "$tmp/$1.out")" "[$1] one ADWRAPPER_SUMMARY line ($2)"
}

# ---- fixture: expected lines in every registry-reading mode ----------------------------
for shim in - nojq jq15; do
  tag=${shim#-}; tag=${tag:-jq}
  run_dw "fx-$tag" "$shim" -- "$FIX" --registry "$REG"
  check_ok "fx-$tag" "fixture, --registry"
  assert_files_eq "$EXPECTED" "$tmp/fx-$tag.adw" "[fx-$tag] ADWRAPPER_* lines == expected"
  assert_eq "" "$(cat "$tmp/fx-$tag.err")" "[fx-$tag] empty stderr"
  run_dw "fxdef-$tag" "$shim" -- "$FIX"
  check_ok "fxdef-$tag" "fixture, default registry"
  assert_files_eq "$EXPECTED" "$tmp/fxdef-$tag.adw" "[fxdef-$tag] default registry: ADWRAPPER_* lines == expected"
  assert_eq "" "$(cat "$tmp/fxdef-$tag.err")" "[fxdef-$tag] empty stderr"
done
for gone in tv.superawesome.lib yads.core.impl backtraceio.library.sub; do
  assert_false "fixture: $gone is excluded (registry .packages)" grep -q ":$gone:" "$tmp/fx-jq.adw"
done
assert_true "fixture: in-house wrapper annotated registry=rovio-beacon" \
  grep -q '^ADWRAPPER_DETECTED:com.rovio.beacon:.*,registry=rovio-beacon$' "$tmp/fx-jq.adw"

# ---- I13: malformed registries --------------------------------------------------------
mkreg() { # mkreg <dir> <file> <content>: the real registry + one bad entry file
  mkdir -p "$1"; cp "$REG"/*.json "$1"/; printf '%s\n' "$3" >"$1/$2"
}
mkreg "$tmp/regD" zz-broken.json '{"sdk_id": broken'
mkreg "$tmp/regE" zz-noid.json '{"display_name":"no id","packages":["com.x.y"]}'
regs="regD:$tmp/regD regE:$tmp/regE"
TOL=$ARE_WORKSPACE/registry-unification/scratch/contract/tol
for r in regD regE; do
  if [ -d "$TOL/$r" ]; then regs="$regs tol-$r:$TOL/$r"; else echo "note: $TOL/$r not found (scratch copy skipped)"; fi
done
for spec in $regs; do
  rn=${spec%%:*} rd=${spec#*:}
  case "$rn" in *regD) bad=zz-broken.json ;; *) bad=zz-noid.json ;; esac
  for shim in - nojq jq15; do
    tag=${shim#-}; tag=${tag:-jq}
    run_dw "$rn-$tag" "$shim" -- "$FIX" --registry "$rd"
    check_ok "$rn-$tag" "$bad is skipped"
    assert_files_eq "$EXPECTED" "$tmp/$rn-$tag.adw" "[$rn-$tag] other entries still read: ADWRAPPER_* lines == expected"
    assert_true "[$rn-$tag] WARN skipping $bad" grep -q "^registry-query: WARN skipping $bad: " "$tmp/$rn-$tag.err"
    assert_false "[$rn-$tag] registry not declared unreadable" grep -qF "$WARN_LINE" "$tmp/$rn-$tag.err"
  done
done

# an unreadable entry file (chmod 000) is a per-file lenient skip in every mode (DESIGN
# 4.3/4.4): same WARN, same exclusions, same output with jq, without jq (awk) and jq 1.5
mkdir -p "$tmp/regP"; cp "$REG"/*.json "$tmp/regP"/; chmod 000 "$tmp/regP/unity-ads.json"
if [ -r "$tmp/regP/unity-ads.json" ]; then
  echo "note: chmod 000 does not make files unreadable here (root?): unreadable-entry case skipped"
else
  for shim in - nojq jq15; do
    tag=${shim#-}; tag=${tag:-jq}
    run_dw "regP-$tag" "$shim" -- "$FIX" --registry "$tmp/regP"
    check_ok "regP-$tag" "unreadable unity-ads.json is skipped"
    assert_eq "registry-query: WARN skipping unity-ads.json: unreadable file" "$(cat "$tmp/regP-$tag.err")" \
      "[regP-$tag] stderr = the per-file WARN only"
    assert_files_eq "$tmp/regP-jq.out" "$tmp/regP-$tag.out" "[regP-$tag] output == jq mode"
    run_dw "dumpP-$tag" "$shim" -- --dump-exclusions --registry "$tmp/regP"
    assert_eq 0 "$(cat "$tmp/dumpP-$tag.rc")" "[dumpP-$tag] exit 0"
    assert_files_eq "$tmp/dumpP-jq.out" "$tmp/dumpP-$tag.out" "[dumpP-$tag] EXCL/INHOUSE == jq mode"
    if [ "$shim" = - ]; then run_bash "$NS/registry-query.sh" --registry "$tmp/regP" packages >/dev/null 2>"$tmp/strictP-$tag.err"
    else with_shim "$shim" run_bash "$NS/registry-query.sh" --registry "$tmp/regP" packages >/dev/null 2>"$tmp/strictP-$tag.err"; fi
    assert_eq 1 "$?" "[strictP-$tag] registry-query packages (strict): exit 1"
    assert_eq "registry-query: ERROR unity-ads.json: unreadable file" "$(cat "$tmp/strictP-$tag.err")" "[strictP-$tag] strict ERROR message"
  done
  # the skipped entry's packages are no longer excluded; the rest of the registry still is
  assert_false "regP: unity-ads packages no longer excluded" grep -qx 'EXCL:com/unity3d/ads' "$tmp/dumpP-jq.out"
  assert_true "regP: more than the static tables (registry still read)" \
    test "$(grep -c '^EXCL:' "$tmp/dumpP-jq.out")" -gt 81
fi

mkdir -p "$tmp/noentry"
printf '{"sdk_id": broken\n' >"$tmp/allbad.json.tmp"
mkdir -p "$tmp/allbad"; cp "$tmp/allbad.json.tmp" "$tmp/allbad/a.json"; : >"$tmp/allbad/b.json"
for spec in "missing:$tmp/does-not-exist" "noentry:$tmp/noentry" "allbad:$tmp/allbad"; do
  rn=${spec%%:*} rd=${spec#*:}
  for shim in - nojq jq15; do
    tag=${shim#-}; tag=${tag:-jq}
    run_dw "$rn-$tag" "$shim" -- "$FIX" --registry "$rd"
    check_ok "$rn-$tag" "unreadable registry"
    assert_true "[$rn-$tag] WARN registry unreadable" grep -qxF "$WARN_LINE" "$tmp/$rn-$tag.err"
    # static tables only: com.rovio.beacon loses its registry= annotation
    assert_true "[$rn-$tag] no registry annotation without a registry" \
      grep -q '^ADWRAPPER_DETECTED:com.rovio.beacon:.*,vendor=no$' "$tmp/$rn-$tag.adw"
  done
done

# ---- --dump-exclusions -------------------------------------------------------------
for shim in - nojq jq15; do
  tag=${shim#-}; tag=${tag:-jq}
  run_dw "dump-$tag" "$shim" -- --dump-exclusions --registry "$REG"
  assert_eq 0 "$(cat "$tmp/dump-$tag.rc")" "[dump-$tag] exit 0 without a decoded dir"
  assert_eq "" "$(cat "$tmp/dump-$tag.err")" "[dump-$tag] empty stderr"
done
assert_files_eq "$tmp/dump-jq.out" "$tmp/dump-nojq.out" "dump: nojq == jq"
assert_files_eq "$tmp/dump-jq.out" "$tmp/dump-jq15.out" "dump: jq15 == jq"
assert_eq "" "$(grep -vE '^(EXCL|INHOUSE):' "$tmp/dump-jq.out")" "dump: only EXCL:/INHOUSE: lines"
grep '^EXCL:' "$tmp/dump-jq.out" | sed 's/^EXCL://' >"$tmp/excl.txt"
sort -u "$tmp/excl.txt" >"$tmp/excl.sorted"
assert_files_eq "$tmp/excl.sorted" "$tmp/excl.txt" "dump: EXCL sorted (C locale) and unique"
for e in com/applovin j\$ com/rovio/beacon/x tv/superawesome/lib yads backtraceio com/adjust/sdk; do
  case "$e" in
    com/rovio/beacon/x) assert_false "dump: in-house package com/rovio/beacon is not excluded" grep -qx 'com/rovio/beacon' "$tmp/excl.txt" ;;
    *) assert_true "dump: EXCL has $e" grep -qxF "$e" "$tmp/excl.txt" ;;
  esac
done
# I12: INHOUSE = the in_house_wrapper rows of registry-query packages, same order
run_bash "$NS/registry-query.sh" --registry "$REG" packages --lenient 2>/dev/null |
  awk -F '\t' '$2 == "true" { p = $3; gsub(/\./, "/", p); print "INHOUSE:" p "|" $1 }' >"$tmp/inhouse.exp"
grep '^INHOUSE:' "$tmp/dump-jq.out" >"$tmp/inhouse.got"
assert_files_eq "$tmp/inhouse.exp" "$tmp/inhouse.got" "dump: INHOUSE == in-house rows of registry-query packages (I12, ordered)"
assert_true "dump: INHOUSE has com/rovio/beacon|rovio-beacon" grep -qxF 'INHOUSE:com/rovio/beacon|rovio-beacon' "$tmp/inhouse.got"
# every registry package (not in-house) is excluded, and nothing else comes from the registry
run_bash "$NS/registry-query.sh" --registry "$REG" packages 2>/dev/null |
  awk -F '\t' '$2 == "false" { p = $3; gsub(/\./, "/", p); print p }' | sort -u >"$tmp/regexcl.exp"
assert_eq "" "$(comm -23 "$tmp/regexcl.exp" "$tmp/excl.txt")" "dump: every non-in-house registry package is in EXCL"
run_dw "dump-missing" - -- --dump-exclusions --registry "$tmp/does-not-exist"
assert_eq 0 "$(cat "$tmp/dump-missing.rc")" "dump, missing registry: exit 0"
assert_true "dump, missing registry: WARN" grep -qxF "$WARN_LINE" "$tmp/dump-missing.err"
assert_eq 0 "$(grep -c '^INHOUSE:' "$tmp/dump-missing.out")" "dump, missing registry: no INHOUSE"
assert_eq 81 "$(grep -c '^EXCL:' "$tmp/dump-missing.out")" "dump, missing registry: the 25 + 56 static roots (81 unique)"

# ---- CLI --------------------------------------------------------------------------
run_bash "$DW" -h >"$tmp/h.out" 2>&1
assert_eq 0 "$?" "-h: exit 0"
assert_true "-h mentions --dump-exclusions" grep -q -- '--dump-exclusions' "$tmp/h.out"
run_bash "$DW" --bogus "$FIX" >/dev/null 2>"$tmp/bogus.err"
assert_eq 1 "$?" "--bogus: exit 1"
assert_true "--bogus: usage on stderr" grep -q '^Usage:' "$tmp/bogus.err"
run_bash "$DW" >/dev/null 2>&1
assert_eq 1 "$?" "no decoded dir: exit 1"
run_bash "$DW" "$tmp/does-not-exist" >/dev/null 2>&1
assert_eq 1 "$?" "missing decoded dir: exit 1"

# ---- I19: decode-apk.sh exit code unchanged ------------------------------------------
# a fake apktool: `apktool d -f -o <dir> <apk>` copies the fixture to <dir>
mkdir -p "$tmp/fakebin"
cat >"$tmp/fakebin/apktool" <<EOF
#!/bin/sh
out=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out=\$2; shift ;; esac; shift; done
[ -n "\$out" ] || exit 1
rm -rf "\$out" && cp -R "$FIX" "\$out"
EOF
chmod +x "$tmp/fakebin/apktool"
: >"$tmp/app.apk"
# a copy of the neutralizer whose default registry is regD (broken entry) / missing
# (decode-apk.sh resolves ../../android-reverse-engineering/scripts under set -e)
for v in real regD noreg; do
  mkdir -p "$tmp/plug-$v/sdk-neutralizer" "$tmp/plug-$v/android-reverse-engineering/scripts"
  cp -R "$NS" "$tmp/plug-$v/sdk-neutralizer/scripts"
  case "$v" in
    real) cp -R "$REG" "$tmp/plug-$v/sdk-neutralizer/registry" ;;
    regD) cp -R "$tmp/regD" "$tmp/plug-$v/sdk-neutralizer/registry" ;;
    noreg) : ;;
  esac
done
for v in real regD noreg; do
  for shim in - nojq; do
    tag=$v-${shim#-}; tag=${tag%-}
    if [ "$shim" = - ]; then
      PATH="$tmp/fakebin:$PATH" run_bash "$tmp/plug-$v/sdk-neutralizer/scripts/decode-apk.sh" "$tmp/app.apk" -o "$tmp/out-$tag" \
        >"$tmp/dec-$tag.out" 2>"$tmp/dec-$tag.err"
    else
      HOME=$NO_HOME PATH="$tmp/fakebin:$TESTS_DIR/shims/$shim:$PATH" run_bash "$tmp/plug-$v/sdk-neutralizer/scripts/decode-apk.sh" "$tmp/app.apk" -o "$tmp/out-$tag" \
        >"$tmp/dec-$tag.out" 2>"$tmp/dec-$tag.err"
    fi
    rc=$?
    assert_eq 0 "$rc" "decode-apk.sh [$tag]: exit 0"
    [ "$rc" = 0 ] || sed 's/^/    | /' "$tmp/dec-$tag.err" | tail -n 10
    assert_true "decode-apk.sh [$tag]: DECODED_DIR line" grep -q '^DECODED_DIR:' "$tmp/dec-$tag.out"
    assert_eq 1 "$(grep -cE '^ADWRAPPER_SUMMARY:(none|candidate)$' "$tmp/dec-$tag.out")" "decode-apk.sh [$tag]: one ADWRAPPER_SUMMARY line"
    assert_false "decode-apk.sh [$tag]: no 'Ad-wrapper check failed'" grep -q 'Ad-wrapper check failed' "$tmp/dec-$tag.out"
    case "$v" in
      real|regD) adw_lines "$tmp/dec-$tag.out" >"$tmp/dec-$tag.adw"
                 assert_files_eq "$EXPECTED" "$tmp/dec-$tag.adw" "decode-apk.sh [$tag]: ADWRAPPER_* lines == expected" ;;
      noreg)     assert_true "decode-apk.sh [$tag]: registry unreadable WARN" grep -qxF "$WARN_LINE" "$tmp/dec-$tag.err" ;;
    esac
  done
done
t_done
