#!/usr/bin/env bash
# t_protection.sh -- detect-protection.sh / .ps1 on synthetic decoded trees (no proprietary
# code): PairIP (signature-vm / license), LVL, Play Integrity and SafetyNet clients, and the
# generic packed-code check (components declared in the manifest but missing from the decoded
# smali): thresholds (>= 3 declared and >= 3 missing; >= 50% medium, >= 80% high),
# activity-alias, android.* framework classes and relative names are not counted, a tree
# with only a commercial packer's file name (no vendor list any more) reports nothing, and
# the ps1 twin prints the same lines when Windows PowerShell is available.
# requires: NS/detect-protection.sh
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
export LC_ALL=C

DP=$NS/detect-protection.sh
mktemp_dir tmp

# mk <dir> <declared-count> <present-count>: manifest declaring Application .App plus
# <declared-count> - 1 activities com.ex.A1..; smali holds the first <present-count> of them
mk() {
  _d=$1 _n=$2 _p=$3
  mkdir -p "$_d/smali/com/ex"
  {
    printf '<?xml version="1.0" encoding="utf-8" standalone="no"?><manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.ex">\n'
    printf '    <application android:name=".App" android:label="x">\n'
    _i=1
    while [ "$_i" -lt "$_n" ]; do
      printf '        <activity android:exported="false" android:name="com.ex.A%s"/>\n' "$_i"
      _i=$((_i + 1))
    done
    printf '        <activity-alias android:name="com.ex.Alias" android:targetActivity="com.ex.A1"/>\n'
    printf '        <service android:name="android.app.SomeFrameworkService"/>\n'
    printf '    </application>\n</manifest>\n'
  } >"$_d/AndroidManifest.xml"
  _i=0
  while [ "$_i" -lt "$_p" ]; do
    if [ "$_i" -eq 0 ]; then _f=App; else _f=A$_i; fi
    printf '.class public Lcom/ex/%s;\n' "$_f" >"$_d/smali/com/ex/$_f.smali"
    _i=$((_i + 1))
  done
}
detected() { run_bash "$DP" "$1" | grep -E '^PROTECTION_DETECTED' | cut -d: -f2-4; }
summary()  { run_bash "$DP" "$1" | sed -n 's/^PROTECTION_SUMMARY://p'; }

# ---- clean app --------------------------------------------------------------------------
mk "$tmp/clean" 10 10
assert_eq none "$(summary "$tmp/clean")" "clean app: summary none"
assert_eq "" "$(detected "$tmp/clean")" "clean app: nothing detected"

# ---- packed-code thresholds (declared = Application + 9 activities = 10) -----------------
mk "$tmp/m4" 10 6      # 4 missing = 40%
assert_eq none "$(summary "$tmp/m4")" "4/10 missing: below 50%, nothing"
mk "$tmp/m5" 10 5      # 5 missing = 50%
assert_eq "packed-code:hardener:medium" "$(detected "$tmp/m5")" "5/10 missing: medium"
mk "$tmp/m8" 10 2      # 8 missing = 80%
assert_eq "packed-code:hardener:high" "$(detected "$tmp/m8")" "8/10 missing: high"
assert_eq hardener "$(summary "$tmp/m8")" "8/10 missing: summary hardener"
ev=$(run_bash "$DP" "$tmp/m8" | sed -n 's/^PROTECTION_DETECTED:packed-code:hardener:high://p')
case "$ev" in declared-classes-missing=8/10,absent=com/ex/A2,absent=com/ex/A3,absent=com/ex/A4) pass_check evidence ;;
  *) fail_check "evidence: $ev" ;; esac
mk "$tmp/few" 3 0      # 3 declared, 3 missing, but... exactly the minimum
assert_eq "packed-code:hardener:high" "$(detected "$tmp/few")" "3/3 missing: reported (minimum size)"
mk "$tmp/tiny" 2 0     # 2 declared: too small to judge
assert_eq none "$(summary "$tmp/tiny")" "2 declared: too few to judge"

# ---- the output never names a vendor (no vendor list) -------------------------------------
out=$(run_bash "$DP" "$tmp/m8")
if printf '%s\n' "$out" | grep -qiE 'dexguard|promon|appdome|verimatrix|arxan|bangcle|secneo|jiagu|legu|ijiami|baidu|alibaba|yidun|dexprotector|appsealing|liapp'; then
  fail_check "output names a vendor"; else pass_check "no vendor named"; fi
mk "$tmp/vendorfile" 10 10
mkdir -p "$tmp/vendorfile/lib/arm64-v8a" && : >"$tmp/vendorfile/lib/arm64-v8a/libjiagu.so"
assert_eq none "$(summary "$tmp/vendorfile")" "a commercial packer's file name alone is not a signal any more"

# ---- PairIP, LVL, Play Integrity, SafetyNet ---------------------------------------------
mk "$tmp/pairip" 10 10
mkdir -p "$tmp/pairip/smali/com/pairip" && : >"$tmp/pairip/smali/com/pairip/SignatureCheck.smali"
assert_eq "pairip-signature-vm:signature-vm:high" "$(detected "$tmp/pairip")" "PairIP signature check"
mk "$tmp/lic" 10 10
mkdir -p "$tmp/lic/smali/com/pairip/licensecheck" && : >"$tmp/lic/smali/com/pairip/licensecheck/LicenseClient.smali"
assert_eq "pairip-license:license:high" "$(detected "$tmp/lic")" "PairIP license check"
mk "$tmp/lvl" 10 10
mkdir -p "$tmp/lvl/smali/com/google/android/vending/licensing"
assert_eq "lvl:license:medium" "$(detected "$tmp/lvl")" "LVL"
mk "$tmp/integ" 10 10
mkdir -p "$tmp/integ/smali/com/google/android/play/core/integrity" "$tmp/integ/smali/com/google/android/gms/safetynet"
assert_eq "play-integrity:integrity:low
safetynet:integrity:low" "$(detected "$tmp/integ")" "Play Integrity and SafetyNet clients"
assert_eq integrity "$(summary "$tmp/integ")" "integrity summary"

# ---- errors and exit code -------------------------------------------------------------------
run_bash "$DP" "$tmp/does-not-exist" >/dev/null 2>&1; assert_eq 1 "$?" "missing directory: rc 1"
run_bash "$DP" "$tmp/m8" >/dev/null 2>&1; assert_eq 0 "$?" "detection is informational: rc 0"

# ---- ps1 twin ---------------------------------------------------------------------------------
if have_ps && command -v wslpath >/dev/null 2>&1; then
  PS1=$NS/detect-protection.ps1
  for t in clean m5 m8 few tiny vendorfile pairip lic lvl integ; do
    a=$(bash "$TESTS_DIR/parity/ps.sh" "$PS1" "$(wslpath -w "$tmp/$t")" 2>&1 | tr -d '\r' | tail -n +2)
    b=$(run_bash "$DP" "$tmp/$t" | tail -n +2)
    assert_eq "$b" "$a" "ps1 == sh on $t"
  done
fi
t_done
