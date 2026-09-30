#!/usr/bin/env bash
# t_parity.sh -- sh/ps1 parity through Windows PowerShell 5.1 (DESIGN 9.1 I21, I22).
# Usage: t_parity.sh [--only <section>]...     sections: registry-query adwrapper
#
# registry-query (I21): registry-query.ps1 run with -File (the way the docs tell users:
# tests/parity/ps.sh) prints the same bytes as registry-query.sh for rows / shared /
# packages -- after removing the single CR of the CRLF the PowerShell host appends --
# on tests/fixtures/registry-{mini,edge,bad} (strict and --lenient), on the real registry
# and on a copy on a Windows drive; stderr (ERROR/WARN lines, incl. BOM and case-colliding
# keys) and exit codes are identical; usage / directory errors have the same exit code
# and message. In-process: `$x = & registry-query.ps1 ...` captures one string with LF
# inside, dot-sourcing registry-lib.ps1 leaves the caller's variables alone (no param()
# block, no global state), [Console]::OutputEncoding is restored, and Get-LongPath maps
# drive and UNC roots to \\?\ and \\?\UNC\.
# adwrapper (I8/I9, I13, I19; DESIGN 6): detect-adwrapper.ps1 prints the same ADWRAPPER_*
# lines as detect-adwrapper.sh, exits 0 and warns the same way on malformed / unreadable
# registries (tests/fixtures/make-adwrapper-fixture.sh + regD/regE-like copies of the
# registry, and regP: one entry file chmod 000), and -DumpExclusions == --dump-exclusions.
# In-process: decode-apk.ps1 (run with `&` from a driver, a fake apktool.cmd "decodes"
# the fixture) calls `& detect-adwrapper.ps1` in-process: same ADWRAPPER_* lines as
# -File, $LASTEXITCODE 0, caller's $Registry intact.
# Corpus part (8 apps: sh --registry == ps1 -File -Registry == ps1 in-process via `&` as
# decode-apk.ps1 calls it, $LASTEXITCODE 0): only when the section is named with --only
# or under `run.sh full` (ARE_FULL=1): it takes a few minutes.
# SKIP when PowerShell is not reachable (ARE_PS=none).
# requires: NS/registry-query.sh NS/registry-query.ps1 NS/registry-lib.ps1
# requires: cmd: have_jq16
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
export LC_ALL=C

only=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only) [ $# -ge 2 ] || die "--only needs a section"; only="$only $2"; shift ;;
    --only=*) only="$only ${1#--only=}" ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done
for s in $only; do case "$s" in registry-query|adwrapper) ;; *) die "unknown section: $s (known: registry-query adwrapper)" ;; esac; done
want() { [ -z "$only" ] && return 0; case " $only " in *" $1 "*) return 0 ;; esac; return 1; }

have_ps || skip "PowerShell not available (ARE_PS=$ARE_PS)"
command -v wslpath >/dev/null 2>&1 || skip "wslpath not available"
PSH=$TESTS_DIR/parity/ps.sh
mktemp_dir tmp

# strip_final_cr <file>: drop the CR of a final CRLF (the one the PowerShell host adds)
strip_final_cr() {
  if [ "$(tail -c 2 "$1" | od -An -tx1 | tr -d ' \n')" = 0d0a ]; then
    _sz=$(wc -c <"$1" | tr -d ' ')
    head -c $((_sz - 2)) "$1" >"$1.tmp" && printf '\n' >>"$1.tmp" && mv "$1.tmp" "$1"
  fi
}
count_cr() { tr -cd '\r' <"$1" | wc -c | tr -d ' '; }
# win_tmp: a writable directory on a Windows drive (not the \\wsl.localhost UNC path), or ""
win_tmp() {
  for _c in "${ARE_WINTMP:-}" /mnt/c/Users/*/AppData/Local/Temp /mnt/c/Windows/Temp; do
    [ -n "$_c" ] && [ -d "$_c" ] && [ -w "$_c" ] && { echo "$_c"; return 0; }
  done
  return 0
}

# ---- section registry-query -------------------------------------------------------------
section_registry_query() {
  RQS=$NS/registry-query.sh
  RQP=$NS/registry-query.ps1
  FIX=$TESTS_DIR/fixtures
  n_cases=0
  # pair <name> <registry-dir> <args...>: run both twins, compare stdout/stderr/rc
  pair() {
    _n=$1 _d=$2; shift 2
    n_cases=$((n_cases + 1))
    run_bash "$RQS" --registry "$_d" "$@" >"$tmp/$_n.sh.out" 2>"$tmp/$_n.sh.err"; _rs=$?
    bash "$PSH" "$RQP" --registry "$(wslpath -w "$_d")" "$@" >"$tmp/$_n.ps.out" 2>"$tmp/$_n.ps.err"; _rp=$?
    assert_eq "$_rs" "$_rp" "[$_n] same exit code"
    strip_final_cr "$tmp/$_n.ps.out"
    assert_eq 0 "$(count_cr "$tmp/$_n.ps.out")" "[$_n] ps1 stdout: no CR besides the host's final one"
    assert_files_eq "$tmp/$_n.sh.out" "$tmp/$_n.ps.out" "[$_n] stdout byte-identical"
    assert_files_eq "$tmp/$_n.sh.err" "$tmp/$_n.ps.err" "[$_n] stderr byte-identical"
  }
  for d in mini edge bad; do
    for v in rows packages shared; do pair "$d.$v" "$FIX/registry-$d" "$v"; done
    for v in rows packages; do pair "$d.$v.lenient" "$FIX/registry-$d" "$v" --lenient; done
  done
  for v in rows shared packages; do pair "real.$v" "$REG" "$v"; done
  assert_true "edge: BOM reported by both twins" grep -q 'a-bom.json: BOM not allowed' "$tmp/edge.rows.ps.err"
  assert_true "edge: case-colliding keys reported by both twins" grep -q 'case-colliding keys: ' "$tmp/edge.rows.ps.err"
  # an unreadable entry file (chmod 000): the same per-file message in both twins
  mkdir -p "$tmp/unr"; cp "$FIX/registry-mini/"*.json "$tmp/unr/"; chmod 000 "$tmp/unr/beta.json"
  if [ -r "$tmp/unr/beta.json" ]; then
    echo "note: chmod 000 does not make files unreadable here (root?): unreadable-entry case skipped"
  else
    for v in rows packages; do pair "unr.$v" "$tmp/unr" "$v"; pair "unr.$v.lenient" "$tmp/unr" "$v" --lenient; done
    assert_eq "registry-query: WARN skipping beta.json: unreadable file" "$(cat "$tmp/unr.packages.lenient.ps.err")" "unreadable entry: ps1 WARN"
  fi

  # a copy on a Windows drive (not the \\wsl.localhost UNC path)
  wtmp=""
  for c in "${ARE_WINTMP:-}" /mnt/c/Users/*/AppData/Local/Temp /mnt/c/Windows/Temp; do
    [ -n "$c" ] && [ -d "$c" ] && [ -w "$c" ] && { wtmp=$c; break; }
  done
  if [ -n "$wtmp" ]; then
    wdir=$(mktemp -d "$wtmp/are-rq.XXXXXX")
    cp -r "$FIX/registry-mini" "$wdir/registry-mini"
    bash "$PSH" "$RQP" rows -Registry "$(wslpath -w "$wdir/registry-mini")" >"$tmp/wcopy.out" 2>"$tmp/wcopy.err"
    assert_eq 0 "$?" "[drive copy] rows exit 0 (-Registry after the verb)"
    strip_final_cr "$tmp/wcopy.out"
    assert_files_eq "$tmp/mini.rows.sh.out" "$tmp/wcopy.out" "[drive copy] rows == sh"
  else
    echo "note: no writable Windows temp dir: drive-copy case skipped"
  fi

  # errors: same exit code; same message once the Windows path is mapped back
  errpair() { # errpair <name> <linux-dir> <args...>
    _n=$1 _d=$2; shift 2
    run_bash "$RQS" --registry "$_d" "$@" >/dev/null 2>"$tmp/$_n.sh.err"; _rs=$?
    bash "$PSH" "$RQP" --registry "$(wslpath -w "$_d")" "$@" >/dev/null 2>"$tmp/$_n.ps.err"; _rp=$?
    assert_eq "$_rs" "$_rp" "[$_n] same exit code"
    assert_eq "$(cat "$tmp/$_n.sh.err")" "$(replace_literal "$(wslpath -w "$_d")" "$_d" <"$tmp/$_n.ps.err")" "[$_n] same message"
  }
  mkdir -p "$tmp/empty" "$tmp/noshared" "$tmp/allbad"
  cp "$FIX/registry-mini/_audit-shared.json" "$tmp/empty/"
  cp "$FIX/registry-mini/alpha.json" "$tmp/noshared/"
  cp "$FIX/registry-mini/_audit-shared.json" "$FIX/registry-bad/c-empty.json" "$FIX/registry-bad/f-noid.json" "$tmp/allbad/"
  errpair missing "$tmp/does-not-exist" rows
  errpair empty "$tmp/empty" packages
  errpair noshared "$tmp/noshared" rows
  errpair allbad "$tmp/allbad" rows --lenient
  for args in "" "bogus" "--bogus rows" "rows packages" "ROWS"; do
    # shellcheck disable=SC2086
    run_bash "$RQS" $args >/dev/null 2>"$tmp/u.sh.err"; _rs=$?
    # shellcheck disable=SC2086
    bash "$PSH" "$RQP" $args >/dev/null 2>"$tmp/u.ps.err"; _rp=$?
    assert_eq "$_rs" "$_rp" "usage [$args]: same exit code"
    assert_eq "$(head -n 1 "$tmp/u.sh.err")" "$(head -n 1 "$tmp/u.ps.err")" "usage [$args]: same message"
  done
  bash "$PSH" "$RQP" version >"$tmp/ver.out" 2>&1
  assert_eq 0 "$?" "ps1 version: exit 0"
  strip_final_cr "$tmp/ver.out"
  assert_eq "$(printf 'registry-query\t1\tpowershell-5.1')" "$(cat "$tmp/ver.out")" "ps1 version: registry-query<TAB>1<TAB>powershell-5.1"
  bash "$PSH" "$RQP" check-jq >"$tmp/cj.out" 2>&1
  assert_eq 0 "$?" "ps1 check-jq: exit 0 (jq never required on Windows)"
  assert_true "ps1 check-jq: [OK] ... not required" grep -q '^\[OK\] jq not required on Windows' "$tmp/cj.out"
  bash "$PSH" "$RQP" -Help >"$tmp/help.out" 2>&1
  assert_eq 0 "$?" "ps1 -Help: exit 0"
  assert_true "ps1 -Help prints the usage" grep -q 'registry-query.ps1 \[-Registry DIR\] rows' "$tmp/help.out"

  # in-process: capture, no leak from dot-sourcing, encoding restored, Get-LongPath
  mini_w=$(wslpath -w "$FIX/registry-mini")
  out_w=$(wslpath -w "$tmp")
  cat >"$tmp/inproc.ps1" <<EOF
\$ErrorActionPreference = 'Continue'
\$Registry = 'caller-value'
\$Lenient = 'caller-lenient'
\$before = @(Get-Variable | ForEach-Object { \$_.Name })
. '$(wslpath -w "$NS/registry-lib.ps1")'
\$after = @(Get-Variable | ForEach-Object { \$_.Name })
\$new = @(\$after | Where-Object { \$before -notcontains \$_ -and \$_ -ne 'before' })
'NEWVARS:' + (\$new -join ',')
'REGISTRY:' + \$Registry
'LENIENT:' + \$Lenient
'EAP:' + \$ErrorActionPreference
'FUNC:' + [bool](Get-Command Get-RegistryRows -CommandType Function -ErrorAction SilentlyContinue)
\$enc0 = [Console]::OutputEncoding.WebName
\$x = & '$(wslpath -w "$RQP")' --registry '$mini_w' rows
'EXIT:' + \$LASTEXITCODE
'TYPE:' + \$x.GetType().FullName
'ENC:' + (\$enc0 -eq [Console]::OutputEncoding.WebName)
[IO.File]::WriteAllText('$out_w\\inproc.rows', \$x, (New-Object Text.UTF8Encoding(\$false)))
\$y = & '$(wslpath -w "$RQP")' -Registry '$mini_w' packages
[IO.File]::WriteAllText('$out_w\\inproc.packages', \$y, (New-Object Text.UTF8Encoding(\$false)))
\$env:SDK_REGISTRY_DIR = '$mini_w'
\$z = & '$(wslpath -w "$RQP")' packages
[IO.File]::WriteAllText('$out_w\\inproc.envpackages', \$z, (New-Object Text.UTF8Encoding(\$false)))
\$env:SDK_REGISTRY_DIR = \$null
\$z = & '$(wslpath -w "$RQP")' packages
[IO.File]::WriteAllText('$out_w\\inproc.defpackages', \$z, (New-Object Text.UTF8Encoding(\$false)))
\$r = Get-RegistryPackages -Registry '$mini_w'
'PKG:' + \$r.ExitCode + ':' + \$r.Items.Count + ':' + \$r.Items[0].SdkId + ':' + \$r.Items[\$r.Items.Count - 1].InHouse
\$s = Get-RegistryRows -Registry '$(wslpath -w "$FIX/registry-edge")' -Lenient
'ROWSLEN:' + \$s.ExitCode + ':' + \$s.Messages.Count
'LP1:' + (Get-LongPath 'C:\\x\\y')
'LP2:' + (Get-LongPath '\\\\srv\\share\\x')
'LP3:' + (ConvertFrom-LongPath (Get-LongPath '\\\\srv\\share\\x'))
'LP4:' + (Get-LongPath '\\\\?\\C:\\z')
EOF
  bash "$PSH" "$tmp/inproc.ps1" >"$tmp/inproc.out" 2>"$tmp/inproc.err"
  assert_eq 0 "$?" "in-process driver: exit 0"
  tr -d '\r' <"$tmp/inproc.out" >"$tmp/inproc.txt"
  kv() { sed -n "s/^$1://p" "$tmp/inproc.txt"; }
  for k in NEWVARS REGISTRY LENIENT EAP FUNC EXIT TYPE ENC PKG ROWSLEN LP1 LP2 LP3 LP4; do
    assert_eq 1 "$(grep -c "^$k:" "$tmp/inproc.txt")" "in-process driver printed $k"
  done
  assert_eq "" "$(kv NEWVARS)" "dot-sourcing registry-lib.ps1 defines no variable"
  assert_eq "caller-value" "$(kv REGISTRY)" "dot-sourcing leaves the caller's \$Registry alone"
  assert_eq "caller-lenient" "$(kv LENIENT)" "dot-sourcing leaves the caller's \$Lenient alone"
  assert_eq "Continue" "$(kv EAP)" "dot-sourcing leaves \$ErrorActionPreference alone"
  assert_eq "True" "$(kv FUNC)" "dot-sourcing defines Get-RegistryRows"
  assert_eq "0" "$(kv EXIT)" "in-process: \$LASTEXITCODE 0"
  assert_eq "System.String" "$(kv TYPE)" "in-process: output captured as ONE string"
  assert_eq "True" "$(kv ENC)" "in-process: [Console]::OutputEncoding restored"
  printf '\n' >>"$tmp/inproc.rows"; printf '\n' >>"$tmp/inproc.packages"
  assert_files_eq "$tmp/mini.rows.sh.out" "$tmp/inproc.rows" "in-process rows == sh rows (LF inside, no final LF)"
  assert_files_eq "$tmp/mini.packages.sh.out" "$tmp/inproc.packages" "in-process -Registry packages == sh packages"
  printf '\n' >>"$tmp/inproc.envpackages"; printf '\n' >>"$tmp/inproc.defpackages"
  assert_files_eq "$tmp/mini.packages.sh.out" "$tmp/inproc.envpackages" "ps1: SDK_REGISTRY_DIR selects the registry"
  assert_files_eq "$tmp/real.packages.sh.out" "$tmp/inproc.defpackages" "ps1: default registry = <script dir>\\..\\registry"
  assert_eq "0:10:aaa-first:True" "$(kv PKG)" "Get-RegistryPackages returns objects (10 items, sorted, InHouse bool)"
  assert_eq "0:3" "$(kv ROWSLEN)" "Get-RegistryRows -Lenient on edge: exit 0 + 3 WARN messages"
  assert_eq '\\?\C:\x\y' "$(kv LP1)" "Get-LongPath drive root -> \\\\?\\"
  assert_eq '\\?\UNC\srv\share\x' "$(kv LP2)" "Get-LongPath UNC root -> \\\\?\\UNC\\"
  assert_eq '\\srv\share\x' "$(kv LP3)" "ConvertFrom-LongPath undoes Get-LongPath"
  assert_eq '\\?\C:\z' "$(kv LP4)" "Get-LongPath keeps an already prefixed path"
  [ -s "$tmp/inproc.err" ] && { echo "in-process stderr:"; sed 's/^/    /' "$tmp/inproc.err"; }
  echo "registry-query: $n_cases sh/ps1 output pairs compared"
}

# ---- section adwrapper ------------------------------------------------------------------
section_adwrapper() {
  DWS=$NS/detect-adwrapper.sh
  DWP=$NS/detect-adwrapper.ps1
  DWP_W=$(wslpath -w "$DWP")
  WARN_LINE='[WARN] registry unreadable: registry exclusions skipped'
  n_adw=0
  if ! grep -q -- '-DumpExclusions' "$DWP"; then fail_check "detect-adwrapper.ps1 has no -DumpExclusions"; return 0; fi
  FXL=$tmp/adw-fixture
  bash "$TESTS_DIR/fixtures/make-adwrapper-fixture.sh" "$FXL" >/dev/null || { fail_check "make-adwrapper-fixture.sh failed"; return 0; }
  adw() { grep '^ADWRAPPER_' "$1" | tr -d '\r' || true; }

  # -DumpExclusions == --dump-exclusions
  run_bash "$DWS" --dump-exclusions --registry "$REG" >"$tmp/dump.sh" 2>"$tmp/dump.sh.err"
  bash "$PSH" "$DWP" -DumpExclusions -Registry "$(wslpath -w "$REG")" >"$tmp/dump.ps.raw" 2>"$tmp/dump.ps.err"
  assert_eq 0 "$?" "ps1 -DumpExclusions: exit 0"
  tr -d '\r' <"$tmp/dump.ps.raw" >"$tmp/dump.ps"
  assert_files_eq "$tmp/dump.sh" "$tmp/dump.ps" "-DumpExclusions == --dump-exclusions (EXCL order, INHOUSE order)"
  assert_eq "" "$(cat "$tmp/dump.ps.err")" "ps1 -DumpExclusions: empty stderr"
  bash "$PSH" "$DWP" -DumpExclusions >"$tmp/dump.psdef.raw" 2>/dev/null
  tr -d '\r' <"$tmp/dump.psdef.raw" >"$tmp/dump.psdef"
  assert_files_eq "$tmp/dump.sh" "$tmp/dump.psdef" "ps1 default registry = <script dir>\\..\\registry"

  # fixture x registries: real, regD (invalid JSON entry), regE (entry without sdk_id),
  # regP (unreadable entry file: chmod 000, a per-file skip in both twins), missing,
  # no entry file
  mkdir -p "$tmp/adw-regD" "$tmp/adw-regE" "$tmp/adw-regP" "$tmp/adw-noentry"
  cp "$REG"/*.json "$tmp/adw-regP/"; chmod 000 "$tmp/adw-regP/unity-ads.json"
  regP_spec="regP:$tmp/adw-regP"
  if [ -r "$tmp/adw-regP/unity-ads.json" ]; then
    echo "note: chmod 000 does not make files unreadable here (root?): regP case skipped"; regP_spec=""
  fi
  cp "$REG"/*.json "$tmp/adw-regD/"; printf '%s\n' '{"sdk_id": broken' >"$tmp/adw-regD/zz-broken.json"
  cp "$REG"/*.json "$tmp/adw-regE/"; printf '%s\n' '{"display_name":"no id","packages":["com.x.y"]}' >"$tmp/adw-regE/zz-noid.json"
  fxw=$(wslpath -w "$FXL")
  for spec in "real:$REG" "regD:$tmp/adw-regD" "regE:$tmp/adw-regE" ${regP_spec:+"$regP_spec"} "missing:$tmp/adw-missing" "noentry:$tmp/adw-noentry"; do
    rn=${spec%%:*} rd=${spec#*:}
    n_adw=$((n_adw + 1))
    run_bash "$DWS" "$FXL" --registry "$rd" >"$tmp/fx.$rn.sh" 2>"$tmp/fx.$rn.sh.err"; rs=$?
    if [ -d "$rd" ]; then rdw=$(wslpath -w "$rd"); else rdw="$(wslpath -w "$tmp")\\adw-missing"; fi
    bash "$PSH" "$DWP" "$fxw" -Registry "$rdw" >"$tmp/fx.$rn.ps" 2>"$tmp/fx.$rn.ps.err"; rp=$?
    assert_eq 0 "$rs" "[fixture $rn] sh exit 0"
    assert_eq 0 "$rp" "[fixture $rn] ps1 exit 0"
    adw "$tmp/fx.$rn.sh" >"$tmp/fx.$rn.sh.adw"; adw "$tmp/fx.$rn.ps" >"$tmp/fx.$rn.ps.adw"
    assert_true "[fixture $rn] ADWRAPPER_SUMMARY present" grep -q '^ADWRAPPER_SUMMARY:' "$tmp/fx.$rn.ps.adw"
    assert_files_eq "$tmp/fx.$rn.sh.adw" "$tmp/fx.$rn.ps.adw" "[fixture $rn] ADWRAPPER_* lines: ps1 == sh"
    tr -d '\r' <"$tmp/fx.$rn.ps.err" | replace_literal "$rdw" "$rd" >"$tmp/fx.$rn.ps.errn"
    assert_files_eq "$tmp/fx.$rn.sh.err" "$tmp/fx.$rn.ps.errn" "[fixture $rn] stderr: ps1 == sh (WARN lines)"
    case "$rn" in
      missing|noentry) assert_true "[fixture $rn] ps1 warns: registry unreadable" grep -qxF "$WARN_LINE" "$tmp/fx.$rn.ps.errn" ;;
      regD|regE) assert_true "[fixture $rn] ps1 skips the bad entry with a WARN" grep -q '^registry-query: WARN skipping zz-' "$tmp/fx.$rn.ps.errn" ;;
      regP) assert_eq "registry-query: WARN skipping unity-ads.json: unreadable file" "$(cat "$tmp/fx.$rn.ps.errn")" \
              "[fixture $rn] ps1 stderr = the per-file WARN only" ;;
    esac
  done
  if [ -n "$regP_spec" ]; then
    n_adw=$((n_adw + 1))
    run_bash "$DWS" --dump-exclusions --registry "$tmp/adw-regP" >"$tmp/dumpP.sh" 2>/dev/null
    bash "$PSH" "$DWP" -DumpExclusions -Registry "$(wslpath -w "$tmp/adw-regP")" >"$tmp/dumpP.ps.raw" 2>/dev/null
    assert_eq 0 "$?" "[regP] ps1 -DumpExclusions: exit 0"
    tr -d '\r' <"$tmp/dumpP.ps.raw" >"$tmp/dumpP.ps"
    assert_files_eq "$tmp/dumpP.sh" "$tmp/dumpP.ps" "[regP] -DumpExclusions == --dump-exclusions (only unity-ads.json skipped)"
    assert_true "[regP] registry still read (more than the 81 static roots)" test "$(grep -c '^EXCL:' "$tmp/dumpP.ps")" -gt 81
  fi
  assert_files_eq "$TESTS_DIR/fixtures/expected/adwrapper-fixture.txt" "$tmp/fx.real.ps.adw" "[fixture] ps1 lines == expected fixture output"

  # in-process via decode-apk.ps1 (fake apktool.cmd on a Windows drive)
  wtmp=$(win_tmp)
  if [ -n "$wtmp" ]; then
    wdir=$(mktemp -d "$wtmp/are-adw.XXXXXX")
    _T_TMPS="$_T_TMPS
$wdir"
    cp -R "$FXL" "$wdir/fixture"
    mkdir -p "$wdir/fakebin" "$wdir/home" "$wdir/plug/sdk-neutralizer" "$wdir/plug/android-reverse-engineering/scripts"
    cp -R "$NS" "$wdir/plug/sdk-neutralizer/scripts"
    cp -R "$tmp/adw-regD" "$wdir/plug/sdk-neutralizer/registry"
    wd=$(wslpath -w "$wdir")
    printf '@echo off\r\nif not "%%1"=="d" exit /b 1\r\nxcopy /E /I /Q /Y "%s\\fixture" "%%~4" >nul\r\nexit /b %%ERRORLEVEL%%\r\n' "$wd" >"$wdir/fakebin/apktool.cmd"
    : >"$wdir/app.apk"
    {
      echo "\$ErrorActionPreference = 'Stop'"
      echo "\$env:PATH = '$wd\\fakebin;' + \$env:PATH"
      echo "\$env:USERPROFILE = '$wd\\home'"
      echo "Remove-Item Env:SCOOP -ErrorAction SilentlyContinue"
      echo "Remove-Item Env:ChocolateyInstall -ErrorAction SilentlyContinue"
      echo "\$Registry = 'caller-value'"
      echo "Write-Host '=== RUN real'"
      echo "& '$(wslpath -w "$NS/decode-apk.ps1")' '$wd\\app.apk' -Output '$wd\\out-real'"
      echo "Write-Host ('=== EXIT real ' + \$LASTEXITCODE)"
      echo "Write-Host '=== RUN regD'"
      echo "& '$wd\\plug\\sdk-neutralizer\\scripts\\decode-apk.ps1' '$wd\\app.apk' -Output '$wd\\out-regD'"
      echo "Write-Host ('=== EXIT regD ' + \$LASTEXITCODE)"
      echo "Write-Host ('REGISTRY:' + \$Registry)"
    } >"$wdir/drv.ps1"
    bash "$PSH" "$wdir/drv.ps1" >"$tmp/dec.raw" 2>"$tmp/dec.err"
    assert_eq 0 "$?" "decode-apk.ps1 driver: exit 0"
    tr -d '\r' <"$tmp/dec.raw" >"$tmp/dec.out"
    for v in real regD; do
      n_adw=$((n_adw + 1))
      awk -v v="$v" '$0 == "=== RUN " v { on = 1; next } on && /^=== EXIT / { exit } on' "$tmp/dec.out" >"$tmp/dec.$v"
      assert_eq "=== EXIT $v 0" "$(grep "^=== EXIT $v " "$tmp/dec.out")" "[decode-apk.ps1 $v] in-process \$LASTEXITCODE 0"
      assert_true "[decode-apk.ps1 $v] DECODED_DIR line" grep -q '^DECODED_DIR:' "$tmp/dec.$v"
      assert_false "[decode-apk.ps1 $v] no 'Ad-wrapper check failed'" grep -q 'Ad-wrapper check failed' "$tmp/dec.$v"
      adw "$tmp/dec.$v" >"$tmp/dec.$v.adw"
      assert_files_eq "$tmp/fx.real.ps.adw" "$tmp/dec.$v.adw" "[decode-apk.ps1 $v] in-process ADWRAPPER_* lines == -File lines"
    done
    assert_eq "REGISTRY:caller-value" "$(grep '^REGISTRY:' "$tmp/dec.out")" "decode-apk.ps1 in-process: caller's \$Registry intact"
    assert_true "decode-apk.ps1 regD: WARN skipping zz-broken.json on stderr" grep -q 'registry-query: WARN skipping zz-broken.json: invalid JSON' "$tmp/dec.err"
  else
    fail_check "no writable Windows temp dir: decode-apk.ps1 in-process case not run"
  fi

  # corpus: 8 apps, sh == ps1 -File == ps1 in-process (called like decode-apk.ps1 does)
  corpus=0
  case " $only " in *" adwrapper "*) corpus=1 ;; esac
  [ "${ARE_FULL:-0}" = 1 ] && corpus=1
  if [ "$corpus" = 1 ] && have_corpus; then
    printf '%s\n' "\$ErrorActionPreference = 'Stop'" "\$Registry = 'caller-value'" >"$tmp/inapps.ps1"
    for app in $CORPUS_APPS; do
      D=$ARE_CORPUS/$app-decoded
      n_adw=$((n_adw + 1))
      run_bash "$DWS" "$D" --registry "$REG" >"$tmp/app.$app.sh" 2>/dev/null
      bash "$PSH" "$DWP" "$(wslpath -w "$D")" -Registry "$(wslpath -w "$REG")" >"$tmp/app.$app.ps" 2>"$tmp/app.$app.ps.err"
      assert_eq 0 "$?" "[$app] ps1 -File: exit 0"
      adw "$tmp/app.$app.sh" >"$tmp/app.$app.sh.adw"; adw "$tmp/app.$app.ps" >"$tmp/app.$app.ps.adw"
      assert_files_eq "$tmp/app.$app.sh.adw" "$tmp/app.$app.ps.adw" "[$app] ADWRAPPER_* lines: ps1 -File == sh"
      assert_eq "" "$(cat "$tmp/app.$app.ps.err")" "[$app] ps1 -File: empty stderr"
      printf '%s\n' "Write-Host '=== RUN $app'" "& '$DWP_W' -DecodedDir '$(wslpath -w "$D")'" \
        "Write-Host ('=== EXIT $app ' + \$LASTEXITCODE)" >>"$tmp/inapps.ps1"
    done
    printf '%s\n' "Write-Host ('REGISTRY:' + \$Registry)" >>"$tmp/inapps.ps1"
    bash "$PSH" "$tmp/inapps.ps1" >"$tmp/inapps.raw" 2>"$tmp/inapps.err"
    assert_eq 0 "$?" "in-process driver (8 apps): exit 0"
    tr -d '\r' <"$tmp/inapps.raw" >"$tmp/inapps.out"
    for app in $CORPUS_APPS; do
      awk -v v="$app" '$0 == "=== RUN " v { on = 1; next } on && /^=== EXIT / { exit } on' "$tmp/inapps.out" >"$tmp/app.$app.in"
      adw "$tmp/app.$app.in" >"$tmp/app.$app.in.adw"
      assert_eq "=== EXIT $app 0" "$(grep "^=== EXIT $app " "$tmp/inapps.out")" "[$app] in-process \$LASTEXITCODE 0"
      assert_files_eq "$tmp/app.$app.ps.adw" "$tmp/app.$app.in.adw" "[$app] in-process ADWRAPPER_* lines == -File"
    done
    assert_eq "REGISTRY:caller-value" "$(grep '^REGISTRY:' "$tmp/inapps.out")" "in-process (8 apps): caller's \$Registry intact"
    assert_eq "" "$(cat "$tmp/inapps.err")" "in-process (8 apps): empty stderr"
  elif [ "$corpus" = 1 ]; then
    echo "note: apktool corpus not found under $ARE_CORPUS: 8-app part skipped"
  else
    echo "note: 8-app corpus part not run (name the section with --only adwrapper, or run.sh full)"
  fi
  echo "adwrapper: $n_adw sh/ps1 cases compared"
}

ran=0
if want registry-query; then section_registry_query; ran=1; fi
if want adwrapper; then section_adwrapper; ran=1; fi
[ "$ran" = 1 ] || die "no section selected"
t_done
