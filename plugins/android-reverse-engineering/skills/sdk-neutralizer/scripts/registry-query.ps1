# registry-query.ps1 -- PowerShell 5.1 twin of registry-query.sh (DESIGN 4): the
# single reader of the SDK registry. Thin CLI over the function library
# registry-lib.ps1; rows/shared/packages print exactly the bytes of the sh twin
# (with -File the host adds one final CRLF).
#
# Usage:
#   registry-query.ps1 [-Registry DIR] rows     [-Lenient]
#   registry-query.ps1 [-Registry DIR] shared
#   registry-query.ps1 [-Registry DIR] packages [-Lenient]
#   registry-query.ps1 check-jq
#   registry-query.ps1 version
# Options are case-insensitive and accept one or two dashes (-Registry, --registry,
# --registry=DIR); -h / -Help prints this text.
#
# Registry directory: -Registry DIR, else $env:SDK_REGISTRY_DIR, else <script dir>\..\registry.
# Verbs and messages: see registry-query.sh. check-jq always succeeds on Windows (jq
# is not needed: the registry is read with ConvertFrom-Json); version prints
# registry-query<TAB>1<TAB>powershell-<major>.<minor>.
# Output goes to the pipeline as ONE string (lines joined by LF, no final LF), so
# `$x = & .\registry-query.ps1 rows` captures it in-process; stderr gets the
# ERROR/WARN lines. Exit: 0 ok, 1 error (usage, missing directory, integrity).
# In PS 5.1 `> file` writes UTF-16LE: use -File from cmd/bash or `| Out-File -Encoding utf8`.
# ASCII-only source; no param() block (arguments are parsed from $args).

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'registry-lib.ps1')

function Write-RqErr([string]$Text) { [Console]::Error.Write($Text + "`n") }
function Show-RqUsage {
  $out = @()
  foreach ($l in (Get-Content -LiteralPath $PSCommandPath | Select-Object -Skip 1)) {
    if (-not $l.StartsWith('#')) { break }
    $out += ($l -replace '^# ?', '')
  }
  Write-Output ($out -join "`n")
}

$registry = ''
$verb = ''
$lenient = $false
$usageError = ''
$showHelp = $false
$argv = @($args)
for ($i = 0; $i -lt $argv.Count; $i++) {
  $a = [string]$argv[$i]
  if ($a.StartsWith('-') -and $a.Length -gt 1) {
    $name = $a.TrimStart('-')
    $value = $null
    $sep = $name.IndexOfAny([char[]]@([char]'=', [char]':'))
    if ($sep -ge 0) { $value = $name.Substring($sep + 1); $name = $name.Substring(0, $sep) }
    $name = $name.ToLowerInvariant()
    if ($name -eq 'h' -or $name -eq 'help') { $showHelp = $true; break }
    elseif ($name -eq 'registry') {
      if ($null -eq $value) {
        if ($i + 1 -ge $argv.Count) { $usageError = '--registry requires a directory'; break }
        $i++
        $value = [string]$argv[$i]
      }
      $registry = $value
    } elseif ($name -eq 'lenient' -and $null -eq $value) { $lenient = $true }
    else { $usageError = 'unknown option: ' + $a; break }
  } else {
    if ($verb -ne '') { $usageError = 'unexpected argument: ' + $a; break }
    $verb = $a
  }
}
if ($showHelp) { Show-RqUsage; exit 0 }
if ($usageError -eq '' -and $verb -eq '') { $usageError = 'missing verb (rows | shared | packages | check-jq | version)' }
if ($usageError -eq '' -and @('rows', 'shared', 'packages', 'check-jq', 'version') -cnotcontains $verb) { $usageError = 'unknown verb: ' + $verb }
if ($usageError -ne '') {
  Write-RqErr ('registry-query: ' + $usageError)
  Write-RqErr "Run 'registry-query.ps1 -Help' for usage."
  exit 1
}

$code = 0
$prevEncoding = $null
try { $prevEncoding = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { $prevEncoding = $null }
try {
  if ($verb -eq 'version') {
    Write-Output ("registry-query`t1`tpowershell-{0}.{1}" -f $PSVersionTable.PSVersion.Major, $PSVersionTable.PSVersion.Minor)
  } elseif ($verb -eq 'check-jq') {
    Write-Output '[OK] jq not required on Windows (PowerShell reads the registry with ConvertFrom-Json)'
  } else {
    $dir = Resolve-RegistryDir -Registry $registry -DefaultDir (Join-Path (Split-Path -Parent $PSScriptRoot) 'registry')
    $lines = New-Object 'System.Collections.Generic.List[string]'
    if ($verb -eq 'rows') {
      $res = Get-RegistryRows -Registry $dir -Lenient:$lenient
      foreach ($r in $res.Items) {
        $lines.Add((ConvertTo-RegistryTsvField $r.SdkId) + "`t" + (ConvertTo-RegistryTsvField $r.Category) + "`t" +
                   (ConvertTo-RegistryTsvField $r.Field) + "`t" + (ConvertTo-RegistryTsvField $r.Value))
      }
    } elseif ($verb -eq 'packages') {
      $res = Get-RegistryPackages -Registry $dir -Lenient:$lenient
      foreach ($r in $res.Items) {
        $ih = 'false'
        if ($r.InHouse) { $ih = 'true' }
        $lines.Add((ConvertTo-RegistryTsvField $r.SdkId) + "`t" + $ih + "`t" + (ConvertTo-RegistryTsvField $r.Package))
      }
    } else {
      $res = Get-RegistryShared -Registry $dir
      foreach ($r in $res.Items) {
        $lines.Add((ConvertTo-RegistryTsvField $r.Kind) + "`t" + (ConvertTo-RegistryTsvField $r.Key) + "`t" + (ConvertTo-RegistryTsvField $r.Value))
      }
    }
    foreach ($m in $res.Messages) { Write-RqErr $m }
    $code = $res.ExitCode
    if ($code -eq 0 -and $lines.Count -gt 0) { Write-Output ($lines.ToArray() -join "`n") }
  }
} finally {
  if ($null -ne $prevEncoding) { try { [Console]::OutputEncoding = $prevEncoding } catch { } }
}
exit $code
