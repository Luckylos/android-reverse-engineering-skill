#!/usr/bin/env bash
# t_parity.sh -- sh/ps1 parity through Windows PowerShell 5.1 (DESIGN 9.1 I21, I22).
# Usage: t_parity.sh [--only <section>]...     sections: registry-query
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
for s in $only; do case "$s" in registry-query) ;; *) die "unknown section: $s (known: registry-query)" ;; esac; done
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

ran=0
if want registry-query; then section_registry_query; ran=1; fi
[ "$ran" = 1 ] || die "no section selected"
t_done
