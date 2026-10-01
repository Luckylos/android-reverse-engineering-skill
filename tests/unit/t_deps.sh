#!/usr/bin/env bash
# t_deps.sh -- jq as a dependency (DESIGN 8 and 9.2; invariants I18, I20):
#   - install-dep.sh jq: [OK] when a jq >= 1.6 is on PATH; Homebrew; the system package
#     only with working sudo (fake sudo + apt-get), then the probe again (a distro jq 1.5
#     goes on to the static binary); without sudo (tests/shims/nosudo) and with no jq
#     (nojq) or an old one (jq15) the pinned static binary lands in ~/.local/bin/jq
#     (download simulated: ARE_JQ_URL=file://<fixture> + ARE_JQ_SHA256, test hooks only);
#     after it, with ~/.local/bin not on the caller's PATH, registry-query check-jq /
#     version, both checkers and a second install-dep.sh jq all use that jq (rc 0, [OK]);
#     with an old/broken jq BEFORE ~/.local/bin on the caller's PATH, the first run
#     installs and then exits 2 with the PATH fix, a second run exits 2 without
#     downloading again (no install-and-retry loop), and once ~/.local/bin comes first
#     everyone says OK (also checked inside neutralize-all, where other installers put
#     ~/.local/bin first on the script's own PATH: needs a real APKEditor JAR, else a note);
#     a failed download / wrong hash -> exit 2 with the URL and the hash; the release URL
#     and the pinned hash per OS/arch (fake uname + fake curl); unsupported arch and
#     MINGW/MSYS -> exit 2 with instructions; usage / unknown-dep lists mention jq;
#   - install-dep.sh neutralize-all: jq is a true soft-fail (subshell): a failing jq
#     install prints "[WARN] jq not installed (optional)" and the exit code and the rest
#     of the output are those of the $ARE_BASE_COMMIT script in the same environment
#     (all deps OK -> 0; only the build-tools license missing -> 2);
#   - check-deps.sh / check-neutralize-deps.sh: INSTALL_OPTIONAL:jq only when jq is missing
#     (nojq) or older than 1.6 (jq15), never INSTALL_REQUIRED:jq; exit code unchanged
#     from $ARE_BASE_COMMIT (also when a required dep is missing); with jq OK the output is
#     the old one plus the single [OK] jq line;
#   - every INSTALL_* name the checkers can print is an install-dep target (same platform;
#     known pre-existing gaps listed below, a stale gap entry fails);
#   - Windows (PowerShell 5.1 via interop, when reachable): check-deps.ps1 and
#     check-neutralize-deps.ps1 print "[OK] jq not required on Windows ..." and never an
#     INSTALL_*:jq line (I20), exit code and INSTALL_* set unchanged from $ARE_BASE_COMMIT;
#     install-dep.ps1 jq -> [OK] + exit 0; the jq lines of the .ps1 files are ASCII.
# install-dep.sh and check-neutralize-deps.sh run with $BASH32 when set (bash 3.2).
# requires: S/android-reverse-engineering/scripts/install-dep.sh S/android-reverse-engineering/scripts/check-deps.sh NS/check-neutralize-deps.sh
# requires: cmd: grep -q install_jq "$S/android-reverse-engineering/scripts/install-dep.sh"
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
export LC_ALL=C

SCR=$S/android-reverse-engineering/scripts
ID=$SCR/install-dep.sh
CD=$SCR/check-deps.sh
CND=$NS/check-neutralize-deps.sh
BASH_BIN=${BASH32:-$(command -v bash)}
BASEPATH=/usr/bin:/bin
SH_NOJQ=$TESTS_DIR/shims/nojq
SH_JQ15=$TESTS_DIR/shims/jq15
SH_NOSUDO=$TESTS_DIR/shims/nosudo
JQ_REL=https://github.com/jqlang/jq/releases/download/jq-1.8.2
# DESIGN 8 pins (verified against the release's sha256sum.txt)
PIN_LINUX_AMD64=b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f
PIN_LINUX_ARM64=8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309
PIN_MACOS_AMD64=e94b266e3c26690550006abe63152b782280f4e14374accdf04cbde844f00bc0
PIN_MACOS_ARM64=2d75340ba57a4b4b4c8708a21c2dc8e958a48aaa8bba13b27f77f6e4c0eca07e
# INSTALL_* names the checkers print that install-dep has no target for (pre-existing,
# not jq): python3 -> optional commit 10b (DESIGN 8, last rows); unzip -> not planned.
KNOWN_GAPS_SH="python3 unzip"
mktemp_dir tmp
echo "bash: $BASH_BIN"

mkexe() { # mkexe <path> <content>
  mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" >"$1"; chmod 755 "$1"
}
has_line() { grep -qxF -- "$2" "$1"; }      # has_line <file> <exact line>
has_text() { grep -qF -- "$2" "$1"; }       # has_text <file> <substring>
count_x() { grep -cxF -- "$2" "$1" || true; }

# The scripts of $ARE_BASE_COMMIT, in the same layout (check-neutralize-deps.sh finds
# install-dep.sh through ../../android-reverse-engineering/scripts).
OLD=$tmp/old
for f in android-reverse-engineering/scripts/install-dep.sh android-reverse-engineering/scripts/check-deps.sh \
         android-reverse-engineering/scripts/check-deps.ps1 sdk-neutralizer/scripts/check-neutralize-deps.sh \
         sdk-neutralizer/scripts/check-neutralize-deps.ps1; do
  mkdir -p "$OLD/skills/$(dirname "$f")"
  git -C "$REPO" show "$ARE_BASE_COMMIT:plugins/android-reverse-engineering/skills/$f" >"$OLD/skills/$f" 2>/dev/null ||
    die "cannot read $f at ARE_BASE_COMMIT=$ARE_BASE_COMMIT"
done
OLD_ID=$OLD/skills/android-reverse-engineering/scripts/install-dep.sh
OLD_CD=$OLD/skills/android-reverse-engineering/scripts/check-deps.sh
OLD_CND=$OLD/skills/sdk-neutralizer/scripts/check-neutralize-deps.sh

# Fixture "jq": passes the >= 1.6 feature probe and says jq-1.8.2 (no real jq needed).
FIX=$tmp/fixture/jq
mkexe "$FIX" '#!/bin/sh
# t_deps fixture jq: answers --version and the >= 1.6 probe of install-dep / check-deps
case "$1" in --version) echo "jq-1.8.2"; exit 0 ;; esac
echo true'
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }
FIXSHA=$(sha256 "$FIX")
FJQ=$tmp/fjq; mkdir -p "$FJQ"; cp "$FIX" "$FJQ/jq"
# fake sleep (download retries do not wait)
FSLEEP=$tmp/fsleep; mkexe "$FSLEEP/sleep" '#!/bin/sh
exit 0'

# run_id <label> <path-prefix> <script> <args> [VAR=value...]: run install-dep with a fresh
# HOME ($tmp/<label>/home), stdin not a terminal; keep out / err / rc under $tmp/<label>.
run_id() {
  _l=$1; _pp=$2; _scr=$3; _args=$4; shift 4
  mkdir -p "$tmp/$_l/home"
  env -u ARE_JQ_URL -u ARE_JQ_SHA256 -u ANDROID_HOME -u ANDROID_SDK_ROOT -u APKEDITOR_JAR \
    -u ACCEPT_ANDROID_SDK_LICENSE HOME="$tmp/$_l/home" PATH="$_pp:$BASEPATH" "$@" \
    "$BASH_BIN" "$_scr" $_args </dev/null >"$tmp/$_l/out" 2>"$tmp/$_l/err"
  echo $? >"$tmp/$_l/rc"
}
rc_of() { cat "$tmp/$1/rc"; }
show() { echo "    --- $1 stdout"; sed 's/^/    /' "$tmp/$1/out"; echo "    --- $1 stderr"; sed 's/^/    /' "$tmp/$1/err"; }
dest_of() { echo "$tmp/$1/home/.local/bin/jq"; }

# ---- install-dep.sh jq ----------------------------------------------------------------
echo "== install-dep.sh jq"
run_id ok-present "$FJQ:$SH_NOSUDO" "$ID" jq
assert_eq 0 "$(rc_of ok-present)" "jq >= 1.6 on PATH: rc 0"
assert_true "jq >= 1.6 on PATH: [OK] already installed" has_line "$tmp/ok-present/out" "[OK] jq 1.8.2 already installed (>= 1.6)"
assert_false "jq >= 1.6 on PATH: nothing written to HOME" test -e "$tmp/ok-present/home/.local"

for mode in nojq jq15; do
  sh_dir=$SH_NOJQ; [ "$mode" = jq15 ] && sh_dir=$SH_JQ15
  l=static-$mode
  run_id "$l" "$FSLEEP:$sh_dir:$SH_NOSUDO" "$ID" jq ARE_JQ_URL="file://$FIX" ARE_JQ_SHA256="$FIXSHA"
  assert_eq 0 "$(rc_of "$l")" "$mode + no sudo: rc 0 (static binary)" || true
  [ "$(rc_of "$l")" = 0 ] || show "$l"
  d=$(dest_of "$l")
  assert_true "$mode + no sudo: ~/.local/bin/jq installed" test -x "$d"
  assert_true "$mode + no sudo: ~/.local/bin/jq is the downloaded file" cmp -s "$FIX" "$d"
  assert_eq -rwxr-xr-x "$(ls -l "$d" 2>/dev/null | cut -c1-10)" "$mode + no sudo: mode 755"
  assert_true "$mode + no sudo: [OK] installed (SHA-256 verified)" has_line "$tmp/$l/out" "[OK] jq 1.8.2 installed to $d (SHA-256 verified)"
  assert_false "$mode + no sudo: no manual action" has_text "$tmp/$l/err" "MANUAL"
done
assert_true "jq15: says the old jq is too old" has_line "$tmp/static-jq15/out" "[INFO] jq 1.5 found but jq >= 1.6 is needed — installing a newer one."

# After the static install, with ~/.local/bin absent from the caller's PATH, the
# installer, both checkers and the reader resolve the same jq (no install-and-retry loop).
for mode in nojq jq15; do
  sh_dir=$SH_NOJQ; [ "$mode" = jq15 ] && sh_dir=$SH_JQ15
  h=$tmp/static-$mode/home
  run_in() { env HOME="$h" PATH="$sh_dir:$BASEPATH" "$BASH_BIN" "$@" </dev/null 2>&1; }
  out=$(run_in "$NS/registry-query.sh" check-jq); rc=$?
  assert_eq 0 "$rc" "$mode, static jq, ~/.local/bin not on PATH: registry-query check-jq rc 0"
  assert_eq "[OK] jq-1.8.2 detected (>= 1.6)" "$out" "$mode, static jq: registry-query check-jq uses ~/.local/bin/jq"
  assert_eq "$(printf 'registry-query\t1\tjq-1.8.2')" "$(run_in "$NS/registry-query.sh" version)" \
    "$mode, static jq: registry-query version names the jq backend"
  assert_true "$mode, static jq: check-deps.sh says [OK]" sh -c 'printf "%s\n" "$1" | grep -qxF "[OK] jq 1.8.2 detected"' _ "$(run_in "$CD")"
  assert_true "$mode, static jq: check-neutralize-deps.sh says [OK]" sh -c 'printf "%s\n" "$1" | grep -qF "[OK] jq 1.8.2 detected"' _ "$(run_in "$CND")"
  assert_true "$mode, static jq: install-dep.sh jq says already installed" sh -c 'printf "%s\n" "$1" | grep -qxF "[OK] jq 1.8.2 already installed (>= 1.6)"' _ "$(run_in "$ID" jq)"
done
unset -f run_in

# An old (jq15) or broken (nojq) jq comes BEFORE ~/.local/bin on the caller's PATH: the
# reader and the checkers run that one, so the installer must not report success. First
# run: the static binary is downloaded, then exit 2 with the PATH fix naming the
# shadowing jq. Second run: no new download, same exit 2. With ~/.local/bin first, the
# installer, the reader and both checkers all say OK. Also inside neutralize-all, where
# earlier installers may export ~/.local/bin first (the check uses the caller's PATH).
for mode in jq15 nojq; do
  sh_dir=$SH_NOJQ; what="not a working jq"
  [ "$mode" = jq15 ] && { sh_dir=$SH_JQ15; what="jq 1.5, older than 1.6"; }
  l=shadow-$mode; h=$tmp/$l/home; d=$h/.local/bin/jq
  mkdir -p "$h/.local/bin"
  run_sh() { # run_sh <out-label> <args...>: ~/.local/bin LAST on PATH
    _o=$1; shift; mkdir -p "$tmp/$_o"
    env -u ANDROID_HOME -u ANDROID_SDK_ROOT -u APKEDITOR_JAR HOME="$h" \
      PATH="$FSLEEP:$sh_dir:$SH_NOSUDO:$BASEPATH:$h/.local/bin" "$@" </dev/null >"$tmp/$_o/out" 2>"$tmp/$_o/err"
    echo $? >"$tmp/$_o/rc"
  }
  run_sh "$l-1" ARE_JQ_URL="file://$FIX" ARE_JQ_SHA256="$FIXSHA" "$BASH_BIN" "$ID" jq
  assert_eq 2 "$(rc_of "$l-1")" "$mode before ~/.local/bin: first run exits 2 (manual action)" || show "$l-1"
  assert_true "$mode before ~/.local/bin: first run installed ~/.local/bin/jq" cmp -s "$FIX" "$d"
  assert_true "$mode before ~/.local/bin: first run says MANUAL ACTION" has_line "$tmp/$l-1/err" "[MANUAL ACTION REQUIRED]"
  assert_true "$mode before ~/.local/bin: names the shadowing jq" has_line "$tmp/$l-1/err" "  jq 1.8.2 in $d works, but $sh_dir/jq ($what)"
  assert_true "$mode before ~/.local/bin: prints the PATH fix" has_line "$tmp/$l-1/err" '    export PATH="$HOME/.local/bin:$PATH"'
  run_sh "$l-2" ARE_JQ_URL="file://$tmp/missing-jq" ARE_JQ_SHA256="$FIXSHA" "$BASH_BIN" "$ID" jq
  assert_eq 2 "$(rc_of "$l-2")" "$mode before ~/.local/bin: second run exits 2" || show "$l-2"
  assert_false "$mode before ~/.local/bin: second run downloads nothing" has_text "$tmp/$l-2/out" "Installing jq"
  assert_false "$mode before ~/.local/bin: second run never says [OK]" has_text "$tmp/$l-2/out" "[OK]"
  assert_true "$mode before ~/.local/bin: second run names the shadowing jq" has_line "$tmp/$l-2/err" "  jq 1.8.2 in $d works, but $sh_dir/jq ($what)"
  # consistent with the reader: as long as the old jq comes first, the reader refuses it
  run_sh "$l-rq" "$BASH_BIN" "$NS/registry-query.sh" check-jq
  assert_eq 2 "$(rc_of "$l-rq")" "$mode before ~/.local/bin: registry-query check-jq still exits 2"
  # after the PATH fix everyone agrees on ~/.local/bin/jq
  run_fixed() { env HOME="$h" PATH="$h/.local/bin:$sh_dir:$SH_NOSUDO:$BASEPATH:$h/.local/bin" "$BASH_BIN" "$@" </dev/null 2>&1; }
  out=$(run_fixed "$ID" jq); rc=$?
  assert_eq 0 "$rc" "$mode, after the PATH fix: install-dep.sh jq rc 0"
  assert_true "$mode, after the PATH fix: install-dep.sh jq says already installed" sh -c 'printf "%s\n" "$1" | grep -qxF "[OK] jq 1.8.2 already installed (>= 1.6)"' _ "$out"
  assert_eq "[OK] jq-1.8.2 detected (>= 1.6)" "$(run_fixed "$NS/registry-query.sh" check-jq)" "$mode, after the PATH fix: registry-query check-jq OK"
  assert_true "$mode, after the PATH fix: check-deps.sh says [OK]" sh -c 'printf "%s\n" "$1" | grep -qxF "[OK] jq 1.8.2 detected"' _ "$(run_fixed "$CD")"
  assert_true "$mode, after the PATH fix: check-neutralize-deps.sh says [OK]" sh -c 'printf "%s\n" "$1" | grep -qF "[OK] jq 1.8.2 detected"' _ "$(run_fixed "$CND")"
done
unset -f run_sh run_fixed

# working sudo + apt-get whose jq is still 1.5 -> pkg_install, probe again, static binary
FSA=$tmp/fsudoapt
mkexe "$FSA/sudo" '#!/bin/sh
[ "$1" = -n ] && shift
exec "$@"'
mkexe "$FSA/apt-get" "#!/bin/sh
echo \"apt-get \$*\" >>'$tmp/apt.log'
exit 0"
run_id sudo-apt-old "$FSA:$FSLEEP:$SH_JQ15" "$ID" jq ARE_JQ_URL="file://$FIX" ARE_JQ_SHA256="$FIXSHA"
assert_eq 0 "$(rc_of sudo-apt-old)" "sudo + apt jq 1.5: rc 0"
assert_true "sudo + apt jq 1.5: apt-get install jq was run" grep -qx 'apt-get install -y -qq jq' "$tmp/apt.log"
assert_true "sudo + apt jq 1.5: then the static binary" test -x "$(dest_of sudo-apt-old)"
assert_true "sudo + apt jq 1.5: says why" has_line "$tmp/sudo-apt-old/out" "[INFO] The apt jq is missing or older than 1.6 — installing the static binary."

# working sudo + apt-get that provides a good jq -> done, no static binary
FSA2=$tmp/fsudoapt2
mkexe "$FSA2/sudo" '#!/bin/sh
[ "$1" = -n ] && shift
exec "$@"'
mkexe "$FSA2/apt-get" "#!/bin/sh
case \"\$*\" in *install*) cp '$FIX' '$FSA2/jq' ;; esac
exit 0"
run_id sudo-apt-good "$FSA2:$SH_NOJQ" "$ID" jq
assert_eq 0 "$(rc_of sudo-apt-good)" "sudo + apt jq >= 1.6: rc 0"
assert_true "sudo + apt jq >= 1.6: installed via apt" has_line "$tmp/sudo-apt-good/out" "[OK] jq 1.8.2 installed via apt"
assert_false "sudo + apt jq >= 1.6: no static binary" test -e "$(dest_of sudo-apt-good)"

# Homebrew
FBREW=$tmp/fbrew
mkexe "$FBREW/brew" "#!/bin/sh
[ \"\$1 \$2\" = 'install jq' ] && cp '$FIX' '$FBREW/jq'
exit 0"
run_id brew "$FBREW:$SH_NOJQ:$SH_NOSUDO" "$ID" jq
assert_eq 0 "$(rc_of brew)" "brew: rc 0"
assert_true "brew: installed via Homebrew" has_line "$tmp/brew/out" "[OK] jq 1.8.2 installed via Homebrew"
assert_false "brew: no static binary" test -e "$(dest_of brew)"

# download failure / wrong hash -> exit 2 with URL and hash, nothing installed
run_id dl-fail "$FSLEEP:$SH_NOJQ:$SH_NOSUDO" "$ID" jq ARE_JQ_URL="file://$tmp/missing-jq" ARE_JQ_SHA256="$FIXSHA"
assert_eq 2 "$(rc_of dl-fail)" "download failure: rc 2"
assert_true "download failure: prints the URL" has_line "$tmp/dl-fail/err" "  Manually download: file://$tmp/missing-jq"
assert_true "download failure: prints the hash" has_line "$tmp/dl-fail/err" "  check that its SHA-256 is $FIXSHA,"
assert_false "download failure: nothing installed" test -e "$(dest_of dl-fail)"
run_id bad-sha "$FSLEEP:$SH_NOJQ:$SH_NOSUDO" "$ID" jq ARE_JQ_URL="file://$FIX" ARE_JQ_SHA256=0000000000000000000000000000000000000000000000000000000000000000
assert_eq 2 "$(rc_of bad-sha)" "wrong hash: rc 2"
assert_true "wrong hash: SHA-256 mismatch reported" has_text "$tmp/bad-sha/err" "[FAIL] SHA-256 mismatch for "
assert_false "wrong hash: nothing installed" test -e "$(dest_of bad-sha)"

# release URL + pinned hash per OS/arch (fake uname, fake curl that logs and fails)
for row in "Linux x86_64 linux-amd64 $PIN_LINUX_AMD64" "Linux aarch64 linux-arm64 $PIN_LINUX_ARM64" \
           "Darwin x86_64 macos-amd64 $PIN_MACOS_AMD64" "Darwin arm64 macos-arm64 $PIN_MACOS_ARM64"; do
  set -- $row
  l=url-$3; fb=$tmp/f$l
  mkexe "$fb/uname" "#!/bin/sh
case \"\$1\" in -s) echo $1 ;; -m) echo $2 ;; *) echo $1 ;; esac"
  mkexe "$fb/curl" "#!/bin/sh
for a in \"\$@\"; do last=\$a; done
echo \"\$last\" >>'$tmp/$l.curl'
exit 22"
  run_id "$l" "$fb:$FSLEEP:$SH_NOJQ:$SH_NOSUDO" "$ID" jq
  assert_eq 2 "$(rc_of "$l")" "$1/$2: rc 2 when the download fails"
  assert_eq "$JQ_REL/jq-$3" "$(sed -n 1p "$tmp/$l.curl" 2>/dev/null)" "$1/$2: downloads jq-$3"
  assert_eq 3 "$(wc -l <"$tmp/$l.curl" 2>/dev/null | tr -d ' ')" "$1/$2: 3 attempts"
  assert_true "$1/$2: prints the pinned hash" has_line "$tmp/$l/err" "  check that its SHA-256 is $4,"
done
for row in "Linux riscv64 none" "MINGW64_NT-10.0-19045 x86_64 mingw" "MSYS_NT-10.0 x86_64 msys"; do
  set -- $row
  l=os-$3; fb=$tmp/f$l
  mkexe "$fb/uname" "#!/bin/sh
case \"\$1\" in -s) echo $1 ;; -m) echo $2 ;; *) echo $1 ;; esac"
  run_id "$l" "$fb:$FSLEEP:$SH_NOJQ:$SH_NOSUDO" "$ID" jq
  assert_eq 2 "$(rc_of "$l")" "$1/$2: rc 2 (manual action)"
  if [ "$3" = none ]; then
    assert_true "$1/$2: no pinned binary" has_line "$tmp/$l/err" "[FAIL] No pinned jq binary for Linux/riscv64."
  else
    for c in "winget install jqlang.jq" "scoop install jq" "choco install jq"; do
      assert_true "$1: suggests '$c'" has_line "$tmp/$l/err" "    $c"
    done
  fi
done

# pins, usage, unknown dependency
assert_true "pin JQ_VERSION=1.8.2" grep -qx 'JQ_VERSION="1.8.2"' "$ID"
for v in "LINUX_AMD64=\"$PIN_LINUX_AMD64\"" "LINUX_ARM64=\"$PIN_LINUX_ARM64\"" "MACOS_AMD64=\"$PIN_MACOS_AMD64\"" "MACOS_ARM64=\"$PIN_MACOS_ARM64\""; do
  assert_true "pin JQ_SHA256_$v" grep -qx "JQ_SHA256_$v" "$ID"
done
run_id usage "$SH_NOSUDO" "$ID" -h
assert_eq 0 "$(rc_of usage)" "-h: rc 0"
assert_true "-h lists jq" grep -q '^  jq  ' "$tmp/usage/out"
run_id bogus "$SH_NOSUDO" "$ID" bogus-dep
assert_eq 1 "$(rc_of bogus)" "unknown dependency: rc 1"
assert_true "unknown dependency: Available lists jq" grep -q '^Available: .*, jq$' "$tmp/bogus/err"

# ---- install-dep.sh neutralize-all: jq soft-fail, exit code unchanged ------------------
echo "== install-dep.sh neutralize-all"
NA=$tmp/na
mkexe "$NA/bin/java" '#!/bin/sh
echo "openjdk version \"17.0.9\" 2023-10-17" >&2'
mkexe "$NA/bin/apktool" '#!/bin/sh
echo "2.11.0"'
mkexe "$NA/bin/zip" '#!/bin/sh
exit 0'
mkdir -p "$NA/sdk/build-tools/36.0.0"
mkexe "$NA/sdk/build-tools/36.0.0/zipalign" '#!/bin/sh
echo "Usage: zipalign [-f] [-p] [-P <pagesize_kb>] [-v] [-z] <align> infile.zip outfile.zip" >&2
exit 2'
mkexe "$NA/sdk/build-tools/36.0.0/apksigner" '#!/bin/sh
exit 0'
: >"$NA/APKEditor.jar"
# drop the jq block (from "--- jq (optional) ---" to the next empty line) of a new output
strip_jq_block() { awk '/^\[INFO\] --- jq \(optional\) ---$/ { skip = 1; next } skip && $0 == "" { skip = 0; next } !skip' "$1"; }
for case_ in "ok $NA/sdk 0" "license none 2"; do
  set -- $case_
  sdkenv="ANDROID_HOME=$2"; [ "$2" = none ] && sdkenv="ARE_T_NOSDK=1"
  for jqmode in fail ok; do
    url="file://$tmp/missing-jq"; [ "$jqmode" = ok ] && url="file://$FIX"
    l=na-$1-jq$jqmode
    run_id "$l" "$NA/bin:$FSLEEP:$SH_NOJQ:$SH_NOSUDO" "$ID" neutralize-all APKEDITOR_JAR="$NA/APKEditor.jar" "$sdkenv" ARE_JQ_URL="$url" ARE_JQ_SHA256="$FIXSHA"
    run_id "$l-old" "$NA/bin:$FSLEEP:$SH_NOJQ:$SH_NOSUDO" "$OLD_ID" neutralize-all APKEDITOR_JAR="$NA/APKEditor.jar" "$sdkenv"
    assert_eq "$3" "$(rc_of "$l-old")" "neutralize-all ($1): the $ARE_BASE_COMMIT script exits $3"
    assert_eq "$(rc_of "$l-old")" "$(rc_of "$l")" "neutralize-all ($1, jq $jqmode): exit code unchanged"
    if [ "$jqmode" = fail ]; then
      assert_eq 1 "$(count_x "$tmp/$l/out" "[WARN] jq not installed (optional)")" "neutralize-all ($1, jq fail): one [WARN] jq not installed (optional)"
      assert_false "neutralize-all ($1, jq fail): no jq installed" test -e "$(dest_of "$l")"
    else
      assert_false "neutralize-all ($1, jq ok): no jq WARN" has_text "$tmp/$l/out" "[WARN] jq not installed"
      assert_true "neutralize-all ($1, jq ok): jq installed" test -x "$(dest_of "$l")"
    fi
    strip_jq_block "$tmp/$l/out" | replace_literal "$tmp/$l/" "$tmp/$l-old/" >"$tmp/$l/out.nojq"
    assert_files_eq "$tmp/$l-old/out" "$tmp/$l/out.nojq" "neutralize-all ($1, jq $jqmode): stdout without the jq block == $ARE_BASE_COMMIT"
    # stderr: the old lines, in order, plus only the jq download failure messages
    grep -v -e 'jq' -e '^curl: ' -e '^  Manually download: ' -e '^  check that its SHA-256 is ' "$tmp/$l/err" >"$tmp/$l/err.nojq"
    assert_files_eq "$tmp/$l-old/err" "$tmp/$l/err.nojq" "neutralize-all ($1, jq $jqmode): stderr without the jq failure messages == $ARE_BASE_COMMIT"
  done
done

# neutralize-all with ~/.local/bin/jq shadowed by jq15 (~/.local/bin LAST on the caller's
# PATH): install_apkeditor (no APKEDITOR_JAR, verified JAR already in ~/.local/share)
# exports ~/.local/bin FIRST before the jq step runs, so only a check on the caller's PATH
# sees the shadowing jq: the jq step must soft-fail (WARN), never say "already installed".
# Needs a real APKEditor 1.4.9 JAR (its pinned hash): $ARE_T_APKEDITOR_JAR, default
# ~/.local/share/apkeditor/APKEditor.jar of the developer; skipped with a note otherwise.
AE_JAR=${ARE_T_APKEDITOR_JAR:-$HOME/.local/share/apkeditor/APKEditor.jar}
AE_PIN=$(sed -n 's/^APKEDITOR_SHA256="\([0-9a-f]*\)"$/\1/p' "$ID")
if [ -f "$AE_JAR" ] && [ -n "$AE_PIN" ] && [ "$(sha256 "$AE_JAR")" = "$AE_PIN" ]; then
  l=na-shadow; h=$tmp/$l/home
  mkdir -p "$h/.local/bin" "$h/.local/share/apkeditor"
  ln -s "$AE_JAR" "$h/.local/share/apkeditor/APKEditor.jar"
  cp "$FIX" "$h/.local/bin/jq"
  env -u APKEDITOR_JAR -u ANDROID_SDK_ROOT -u ARE_JQ_URL -u ARE_JQ_SHA256 HOME="$h" ANDROID_HOME="$NA/sdk" \
    PATH="$NA/bin:$FSLEEP:$SH_JQ15:$SH_NOSUDO:$BASEPATH:$h/.local/bin" "$BASH_BIN" "$ID" neutralize-all \
    </dev/null >"$tmp/$l/out" 2>"$tmp/$l/err"
  echo $? >"$tmp/$l/rc"
  assert_eq 0 "$(rc_of "$l")" "neutralize-all, jq shadowed: rc 0 (jq is optional)" || show "$l"
  assert_true "neutralize-all, jq shadowed: install_apkeditor ran (APKEditor already installed)" has_text "$tmp/$l/out" "[OK] APKEditor 1.4.9 already installed"
  assert_eq 1 "$(count_x "$tmp/$l/out" "[WARN] jq not installed (optional)")" "neutralize-all, jq shadowed: one [WARN] jq not installed (optional)"
  assert_false "neutralize-all, jq shadowed: never 'already installed' for jq" has_text "$tmp/$l/out" "jq 1.8.2 already installed"
  assert_true "neutralize-all, jq shadowed: names the shadowing jq" has_line "$tmp/$l/err" "  jq 1.8.2 in $h/.local/bin/jq works, but $SH_JQ15/jq (jq 1.5, older than 1.6)"
else
  echo "note: neutralize-all with a shadowed jq: skipped (no APKEditor 1.4.9 JAR at $AE_JAR; set ARE_T_APKEDITOR_JAR)"
fi

# ---- check-deps.sh / check-neutralize-deps.sh -------------------------------------------
# run_ck <label> <script> <path-prefix>: HOME holds only a fake Android SDK (zipalign -P,
# apksigner), so ~/.local/bin never shadows the shims; $FCK (java 17, jadx, apktool 2.11)
# comes after <path-prefix>: every required dependency is there unless the prefix hides one.
FCK=$tmp/fck
mkexe "$FCK/java" '#!/bin/sh
echo "openjdk version \"17.0.9\" 2023-10-17" >&2'
mkexe "$FCK/jadx" '#!/bin/sh
echo "1.5.0"'
mkexe "$FCK/apktool" '#!/bin/sh
echo "2.11.0"'
mkexe "$FCK/keytool" '#!/bin/sh
exit 0'
mkexe "$FCK/unzip" '#!/bin/sh
exit 0'
run_ck() {
  mkdir -p "$tmp/$1/home/Android/Sdk/build-tools"
  cp -R "$NA/sdk/build-tools/36.0.0" "$tmp/$1/home/Android/Sdk/build-tools/"
  env -u ANDROID_HOME -u ANDROID_SDK_ROOT -u APKEDITOR_JAR -u FERNFLOWER_JAR_PATH HOME="$tmp/$1/home" \
    PATH="$3:$FCK:$BASEPATH" "$BASH_BIN" "$2" </dev/null >"$tmp/$1/out" 2>"$tmp/$1/err"
  echo $? >"$tmp/$1/rc"
}
FJAVA11=$tmp/fjava11
mkexe "$FJAVA11/java" '#!/bin/sh
echo "openjdk version \"11.0.2\" 2019-01-15" >&2'
for tool in cd cnd; do
  if [ "$tool" = cd ]; then new=$CD; old=$OLD_CD; name=check-deps.sh
    l_missing="[MISSING] jq not found (optional — needed by find-trackers.sh / find-ads.sh)"
    l_old="[WARN] jq 1.5 is older than 1.6 (optional — find-trackers.sh / find-ads.sh need jq >= 1.6)"
    l_ok="[OK] jq 1.8.2 detected"
  else new=$CND; old=$OLD_CND; name=check-neutralize-deps.sh
    l_missing="[WARN] jq not found (optional — detect-adwrapper uses a built-in fallback parser)"
    l_old="[WARN] jq 1.5 is older than 1.6 (optional — detect-adwrapper uses a built-in fallback parser)"
    l_ok="[OK] jq 1.8.2 detected (optional — detect-adwrapper reads the registry with it)"
  fi
  echo "== $name"
  for mode in nojq jq15 ok req; do
    case $mode in
      nojq) pp=$SH_NOJQ; want=$l_missing ;;
      jq15) pp=$SH_JQ15; want=$l_old ;;
      ok)   pp=$FJQ; want=$l_ok ;;
      req)  pp=$FJAVA11:$SH_NOJQ; want=$l_missing ;;
    esac
    run_ck "$tool-$mode" "$new" "$pp"
    run_ck "$tool-$mode-old" "$old" "$pp"
    o=$tmp/$tool-$mode/out
    assert_true "$name ($mode): '$want'" has_line "$o" "$want"
    assert_eq "" "$(grep -x 'INSTALL_REQUIRED:jq' "$o")" "$name ($mode): never INSTALL_REQUIRED:jq"
    if [ "$mode" = ok ]; then
      assert_eq 0 "$(count_x "$o" INSTALL_OPTIONAL:jq)" "$name ($mode): no INSTALL_OPTIONAL:jq"
      grep -vxF -- "$want" "$o" | replace_literal "$S/" "$OLD/skills/" |
        replace_literal "$tmp/$tool-$mode/home/" "$tmp/$tool-$mode-old/home/" >"$o.nojq"
      assert_files_eq "$tmp/$tool-$mode-old/out" "$o.nojq" "$name ($mode): output == $ARE_BASE_COMMIT plus the [OK] jq line"
    else
      assert_eq 1 "$(count_x "$o" INSTALL_OPTIONAL:jq)" "$name ($mode): exactly one INSTALL_OPTIONAL:jq"
    fi
    assert_eq "$(rc_of "$tool-$mode-old")" "$(rc_of "$tool-$mode")" "$name ($mode): exit code unchanged (rc $(rc_of "$tool-$mode-old"))"
    assert_eq "$(grep '^INSTALL_REQUIRED:' "$tmp/$tool-$mode-old/out")" "$(grep '^INSTALL_REQUIRED:' "$o")" "$name ($mode): INSTALL_REQUIRED lines unchanged"
  done
  assert_eq 1 "$(rc_of "$tool-req")" "$name (req): a missing required dep still exits 1"
  assert_eq 0 "$(rc_of "$tool-nojq")" "$name (nojq): no jq alone still exits 0"
  assert_eq 0 "$(rc_of "$tool-jq15")" "$name (jq15): an old jq alone still exits 0"
done
assert_true "check-deps.sh: the §10 command (nojq, grep -x INSTALL_OPTIONAL:jq)" \
  sh -c 'PATH="$1:$PATH" HOME="$2" bash "$3" | grep -qx INSTALL_OPTIONAL:jq' _ "$SH_NOJQ" "$tmp/cd-nojq/home" "$CD"

# ---- every INSTALL_* name is an install-dep target ---------------------------------------
echo "== INSTALL_* names"
sh_names() { # names the bash checkers can print
  sed -n -E -e 's/.*missing_(required|optional)\+=\("([a-z0-9-]+)"\).*/\2/p' \
            -e 's/.*add_(required|optional) "([a-z0-9-]+)".*/\2/p' "$CD" "$CND" | sort -u
}
sh_targets() { # case labels of the install-dep.sh dispatch block
  awk '/^case "\$DEP" in$/ { d = 1; next } d && /^esac$/ { d = 0 } d && /^  [a-z0-9|-]+\)/ {
         s = $1; sub(/\).*/, "", s); n = split(s, a, "|"); for (i = 1; i <= n; i++) print a[i] }' "$ID" | sort -u
}
ps_names() {
  sed -n -E -e 's/.*[$]missing(Required|Optional) [+]= "([a-z0-9-]+)".*/\2/p' \
            -e "s/.*Add-(Required|Optional) '([a-z0-9-]+)'.*/\\2/p" \
         "$SCR/check-deps.ps1" "$NS/check-neutralize-deps.ps1" | sort -u
}
ps_targets() {
  sed -n "s/^    '\\([a-z0-9-]*\\)' *{.*/\\1/p" "$SCR/install-dep.ps1" | sort -u
}
assert_true "check-deps.sh can print jq" sh -c 'grep -qx jq' <<EOF
$(sh_names)
EOF
assert_true "install-dep.sh has a jq target" sh -c 'grep -qx jq' <<EOF
$(sh_targets)
EOF
assert_true "install-dep.ps1 has a jq target" sh -c 'grep -qx jq' <<EOF
$(ps_targets)
EOF
[ "$(sh_names | wc -l)" -ge 8 ] || fail_check "sh_names found too few names: $(sh_names | tr '\n' ' ')"
[ "$(ps_names | wc -l)" -ge 6 ] || fail_check "ps_names found too few names: $(ps_names | tr '\n' ' ')"
for n in $(sh_names); do
  case " $KNOWN_GAPS_SH " in
    *" $n "*) assert_false "known gap '$n' is still not an install-dep.sh target (else drop it from KNOWN_GAPS_SH)" sh -c "printf '%s\n' \"\$1\" | grep -qx '$n'" _ "$(sh_targets)" ;;
    *) assert_true "sh checkers: INSTALL_*:$n is an install-dep.sh target" sh -c "printf '%s\n' \"\$1\" | grep -qx '$n'" _ "$(sh_targets)" ;;
  esac
done
for n in $(ps_names); do
  assert_true "ps1 checkers: INSTALL_*:$n is an install-dep.ps1 target" sh -c "printf '%s\n' \"\$1\" | grep -qx '$n'" _ "$(ps_targets)"
done
assert_eq "" "$(ps_names | grep -x jq)" "ps1 checkers never print INSTALL_*:jq (I20)"
for f in "$SCR/install-dep.ps1" "$SCR/check-deps.ps1" "$NS/check-neutralize-deps.ps1"; do
  assert_eq "" "$(grep -n 'jq' "$f" | LC_ALL=C grep -n "$(printf '[\200-\377]')")" "$(basename "$f"): jq lines are ASCII"
done

# ---- Windows PowerShell 5.1 (I20) --------------------------------------------------------
if have_ps && command -v wslpath >/dev/null 2>&1; then
  echo "== PowerShell 5.1"
  PSH=$TESTS_DIR/parity/ps.sh
  # The $ARE_BASE_COMMIT check-deps.ps1 dies at `& java -version 2>&1` under 'Stop' when a
  # java is on the Windows PATH (PS 5.1 NativeCommandError; fixed in this commit): compare
  # with that script plus the same one-line fix, so only the jq change is measured.
  OLD_CDPS=$OLD/skills/android-reverse-engineering/scripts/check-deps.ps1
  awk '$0 == "    $javaVersionOutput = & java -version 2>&1 | Select-Object -First 1" {
         print "    $ErrorActionPreference = '"'"'Continue'"'"'"; print; print "    $ErrorActionPreference = '"'"'Stop'"'"'"; n++; next }
       { print } END { if (n != 1) exit 1 }' "$OLD_CDPS" >"$OLD_CDPS.fixed" && mv "$OLD_CDPS.fixed" "$OLD_CDPS" ||
    fail_check "could not apply the java -version fix to the $ARE_BASE_COMMIT check-deps.ps1"
  run_ps() { # run_ps <label> <script> [args...]
    _l=$1; shift; mkdir -p "$tmp/$_l"
    bash "$PSH" "$@" </dev/null >"$tmp/$_l/out" 2>"$tmp/$_l/err"
    echo $? >"$tmp/$_l/rc"
    tr -d '\r' <"$tmp/$_l/out" >"$tmp/$_l/out.lf"
  }
  for pair in "check-deps.ps1|$SCR/check-deps.ps1|$OLD/skills/android-reverse-engineering/scripts/check-deps.ps1|[OK] jq not required on Windows (PowerShell scripts parse the registry natively)" \
              "check-neutralize-deps.ps1|$NS/check-neutralize-deps.ps1|$OLD/skills/sdk-neutralizer/scripts/check-neutralize-deps.ps1|[OK] jq not required on Windows (detect-adwrapper.ps1 reads the registry with ConvertFrom-Json)"; do
    IFS='|' read -r name new old want <<EOF
$pair
EOF
    run_ps "ps-$name" "$new"; run_ps "ps-$name-old" "$old"
    o=$tmp/ps-$name/out.lf
    assert_true "$name: '$want'" has_line "$o" "$want"
    assert_eq "" "$(grep 'INSTALL_.*:jq' "$o")" "$name: no INSTALL_*:jq line (I20)"
    assert_eq "$(rc_of "ps-$name-old")" "$(rc_of "ps-$name")" "$name: exit code unchanged (rc $(rc_of "ps-$name-old"))"
    assert_eq "$(grep '^INSTALL_' "$tmp/ps-$name-old/out.lf")" "$(grep '^INSTALL_' "$o")" "$name: INSTALL_* lines unchanged"
  done
  grep -vxF -- "[OK] jq not required on Windows (PowerShell scripts parse the registry natively)" "$tmp/ps-check-deps.ps1/out.lf" >"$tmp/ps-cd.nojq"
  assert_files_eq "$tmp/ps-check-deps.ps1-old/out.lf" "$tmp/ps-cd.nojq" "check-deps.ps1: output == $ARE_BASE_COMMIT plus the [OK] jq line"
  run_ps ps-id-jq "$SCR/install-dep.ps1" jq
  assert_eq 0 "$(rc_of ps-id-jq)" "install-dep.ps1 jq: rc 0"
  assert_true "install-dep.ps1 jq: [OK] not required" has_line "$tmp/ps-id-jq/out.lf" "[OK] jq is not required on Windows: the .ps1 scripts read the registry with ConvertFrom-Json."
  run_ps ps-id-help "$SCR/install-dep.ps1" -h
  assert_eq 0 "$(rc_of ps-id-help)" "install-dep.ps1 -h: rc 0"
  assert_true "install-dep.ps1 -h lists jq" grep -q '^  jq  ' "$tmp/ps-id-help/out.lf"
  run_ps ps-id-bogus "$SCR/install-dep.ps1" bogus-dep
  assert_eq 1 "$(rc_of ps-id-bogus)" "install-dep.ps1 unknown dependency: rc 1"
  assert_true "install-dep.ps1 unknown dependency: Available lists jq" grep -q '^Available: .*, jq$' "$tmp/ps-id-bogus/out.lf"
else
  echo "note: PowerShell not reachable (ARE_PS=$ARE_PS): Windows checks skipped"
fi
t_done
