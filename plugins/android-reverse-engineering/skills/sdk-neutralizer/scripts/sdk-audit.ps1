# sdk-audit.ps1 -- Windows PowerShell 5.1 twin of sdk-audit.sh: the SDK audit engine behind
# find-trackers.ps1 and find-ads.ps1 (tracker-analysis / ad-analysis skills). Same algorithm,
# same tables and same output as the bash engine (DESIGN 5): the SDK registry (read with
# registry-lib.ps1) is the only source of SDK knowledge.
#
# FUNCTION DEFINITIONS ONLY: no param() block, no top-level statement, no global or script
# state, no change to Set-StrictMode, $ErrorActionPreference or [Console]::OutputEncoding
# outside the functions. A wrapper dot-sources it into its own script scope and calls:
#     . $engine
#     Invoke-SdkAudit -Tool 'find-ads' -Argv $args
#     exit $script:SdkAuditExit
# Invoke-SdkAudit writes the whole report to the pipeline as ONE string (lines joined by LF,
# no final LF; with -File the host adds one CRLF), [INFO] / error lines go to stderr, and the
# exit code is left in $script:SdkAuditExit (0 done, 1 error; jq is never needed on Windows,
# so the bash exit code 2 does not exist here). `$x = & find-ads.ps1 D --json` captures the
# report in-process.
#
# Options: see the usage text (Get-SdkAuditUsage). Option tokens are normalized like the sh
# twin (all dashes dropped, case-insensitive: --manifest-path, -ManifestPath); --name:value
# and --name=value in one token work for the valued options (sdk, manifestpath, registry).
# PowerShell splits a one-dash `-name:value` into `-name:` and `value`, so `-sdk:flurry`
# works too; do not use the `-flag:$true` syntax for flags.
#
# Paths: rows name files as <input as passed>\<path relative to the input> with `\`
# separators; --tsv CALL rows use the path relative to the input with `/`, exactly like the
# sh twin (--tsv is the byte-identical parity format). Files are enumerated and read with
# the \\?\ / \\?\UNC\ long-path prefix (Get-LongPath of registry-lib.ps1).
#
# Semantics notes for maintainers (keep in sync with sdk-audit.sh):
#   - grep -F prefilters are reproduced exactly: a line is analysed only when it contains
#     one of the same literal patterns (a trie-shaped .NET regex of escaped literals; a file
#     with a NUL byte is skipped, like grep's "Binary file matches");
#   - the tokenizer regexes are the awk ones (ASCII classes); every string comparison,
#     dictionary and sort is ordinal (byte order of the C locale for ASCII);
#   - text lines are UTF-8, a trailing CR is dropped like awk's sub(/\r$/, "").
# ASCII-only source.

function Invoke-SdkAudit {
  param([string]$Tool, [object[]]$Argv)
  $ErrorActionPreference = 'Stop'
  Set-StrictMode -Version 2.0
  $here = Split-Path -Parent $MyInvocation.MyCommand.ScriptBlock.File
  $code = 1
  $holder = @{ Out = $null }
  $prevEnc = $null
  try { $prevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { $prevEnc = $null }
  try {
    try {
      . (Join-Path $here 'registry-lib.ps1')
      $null = Invoke-SaCore -Tool $Tool -Argv $Argv -Here $here -Holder $holder
      $code = 0
    } catch {
      $m = [string]$_.Exception.Message
      if ($m.StartsWith('SDKAUDIT_EXIT:', [StringComparison]::Ordinal)) { $code = [int]$m.Substring(14) }
      else {
        Write-SaErr ('sdk-audit: internal error: ' + $m + ' (line ' + $_.InvocationInfo.ScriptLineNumber + ')')
        $code = 1
        $holder.Out = $null
      }
    }
    if ($null -ne $holder.Out) { Write-Output $holder.Out }
  } finally {
    if ($null -ne $prevEnc) { try { [Console]::OutputEncoding = $prevEnc } catch { } }
  }
  $script:SdkAuditExit = $code
}

function Write-SaErr([string]$Text) { [Console]::Error.Write($Text + "`n") }
function Stop-Sa([int]$Code) { throw ('SDKAUDIT_EXIT:' + $Code) }

function Get-SdkAuditUsage([string]$Tool) {
  if ($Tool -ceq 'find-trackers') {
    $u = @'
Usage: find-trackers.ps1 <input-dir> [options]

Audit a decoded/decompiled Android app for tracker and analytics SDKs (every tracker
entry of the SDK registry: analytics, attribution, crash_reporting, social).

<input-dir>: an apktool decode dir (AndroidManifest.xml + smali*/), a jadx output dir
(sources/ + resources/), its sources/ dir, a jadx XAPK dir (<split>/sources/), or any
source tree (then pass --manifest-path).

SDK filters (combinable):
  --firebase --adjust --appsflyer --mixpanel --amplitude --segment --braze
  --clevertap --flurry
  --sdk <sdk_id>      any tracker entry of the registry (repeatable; see --list-sdks)
Aspects:
  --generic           generic cross-SDK calls (hints, never evidence)
  --endpoints         known tracker endpoints (registry domains)
  --manifest          AndroidManifest.xml services, receivers, permissions, meta-data
  --entrypoints       tracker SDK calls and references from app code only
  --all               everything (default; also after filters)
Output:
  (default)           text sections: ==== <Section> ====, rows path:line:text
  --summary           one row per SDK with confidence (legacy SDKs + detected tracker entries)
  --tsv               machine-readable rows (one SDK row for every one of the tracker entries)
  --json              JSON report v2 (detected tracker entries only)
                      (--json > --tsv > --summary; they ignore the filters)
Other:
  --manifest-path F   AndroidManifest.xml to use
  --registry DIR      SDK registry directory (default: sdk-neutralizer/registry)
  --list-sdks         list the tracker entries of the registry (TSV) and exit
                      (packages = neutralized by registry-scan; audit_only_packages = never neutralized)
  --full              no 50-row limit on the "<SDK> - References" sections
  --no-hints          leave out the generic hints
  -h, --help          this help
Options are case-insensitive and may use one or two dashes (--sdk:x and --sdk=x work;
do not use the -flag:$true syntax for flags).

Confidence: HIGH = SDK code present (+ its marker class when declared); MEDIUM = code
without the declared marker class (partial), or AndroidManifest only; LOW = app-code
references / endpoints only; NONE = not detected. Rows ending in [sdk_id/role]
name the SDK; role "ref" = class reference, a trailing "?" = import-scoped instance call.
The report is written to the pipeline as one string: `$r = & find-trackers.ps1 D --json`
captures it; in Windows PowerShell 5.1 `> file` writes UTF-16 (use -File from cmd/bash,
or `| Out-File -Encoding utf8`).
Exit: 0 done, 1 error (jq is not needed on Windows).
'@
  } else {
    $u = @'
Usage: find-ads.ps1 <input-dir> [options]

Audit a decoded/decompiled Android app for advertising SDKs and consent frameworks
(every ads, ads_mediation and consent entry of the SDK registry).

<input-dir>: an apktool decode dir (AndroidManifest.xml + smali*/), a jadx output dir
(sources/ + resources/), its sources/ dir, a jadx XAPK dir (<split>/sources/), or any
source tree (then pass --manifest-path).

SDK filters (combinable):
  --admob --unity --ironsource --applovin --facebook (Meta Audience Network)
  --vungle --inmobi --chartboost --pangle --mintegral
  --sdk <sdk_id>      any ads/consent entry of the registry (repeatable; see --list-sdks)
Aspects:
  --formats           ad formats (banner, interstitial, rewarded, native, ...) and
                      ad unit / placement ids
  --mediation         mediation adapters, adapter classes, waterfall configuration
  --consent           UMP, IAB TCF, COPPA, SDK-specific opt-out calls
  --manifest          AndroidManifest.xml ad activities, permissions, meta-data
  --entrypoints       ad SDK calls and references from app code only
  --all               everything (default; also after filters)
Output:
  (default)           text sections: ==== <Section> ====, rows path:line:text
  --summary           one row per SDK with confidence (legacy SDKs + detected ads/consent entries)
  --tsv               machine-readable rows (one SDK row for every one of the ads/consent entries)
  --json              JSON report v2 (detected ads/consent entries only)
                      (--json > --tsv > --summary; they ignore the filters)
Other:
  --manifest-path F   AndroidManifest.xml to use
  --registry DIR      SDK registry directory (default: sdk-neutralizer/registry)
  --list-sdks         list the ads/consent entries of the registry (TSV) and exit
                      (packages = neutralized by registry-scan; audit_only_packages = never neutralized)
  --full              no 50-row limit on the "<SDK> - References" sections
  --no-hints          leave out the hint rows (informational token matches)
  -h, --help          this help
Options are case-insensitive and may use one or two dashes (--sdk:x and --sdk=x work;
do not use the -flag:$true syntax for flags).

Confidence: HIGH = SDK code present (+ its marker class when declared); MEDIUM = code
without the declared marker class (partial), or AndroidManifest only; LOW = app-code
references / endpoints / ad unit ids only; NONE = not detected. Rows ending in
[sdk_id/role] name the SDK; role "ref" = class reference, a trailing "?" =
import-scoped instance call.
The report is written to the pipeline as one string: `$r = & find-ads.ps1 D --json`
captures it; in Windows PowerShell 5.1 `> file` writes UTF-16 (use -File from cmd/bash,
or `| Out-File -Encoding utf8`).
Exit: 0 done, 1 error (jq is not needed on Windows).
'@
  }
  return $u.Replace("`r`n", "`n")
}

# ---- small helpers (ordinal, awk-compatible) ---------------------------------------------
function New-SaDict { return ,(New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)) }
function New-SaSDict { return ,(New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)) }
function New-SaIDict { return ,(New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::Ordinal)) }
function New-SaList { return ,(New-Object 'System.Collections.Generic.List[string]') }
function New-SaOList { return ,(New-Object 'System.Collections.Generic.List[object]') }
function New-SaSet { return ,(New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)) }

function Split-SaWs([string]$S) {
  # awk split(s, a, " "): runs of blanks, leading/trailing ignored
  return ,($S.Split([char[]]@([char]' ', [char]"`t", [char]"`n"), [StringSplitOptions]::RemoveEmptyEntries))
}
function Get-SaAt($Arr, [int]$I) { if ($I -lt $Arr.Length) { return [string]$Arr[$I] }; return '' }
function Get-SaParent([string]$P) { $i = $P.LastIndexOf([char]'.'); if ($i -lt 0) { return '' }; return $P.Substring(0, $i) }
function Get-SaLastSeg([string]$P) { $i = $P.LastIndexOf([char]'.'); if ($i -lt 0) { return $P }; return $P.Substring($i + 1) }
function Get-SaStripLastSeg([string]$P) {
  # awk sub(/\.[^.]*$/, "", p): unchanged when there is no dot
  $i = $P.LastIndexOf([char]'.'); if ($i -lt 0) { return $P }; return $P.Substring(0, $i)
}
function Get-SaNseg([string]$S) { if ($S.Length -eq 0) { return 0 }; return $S.Split([char]'.').Length }
function Get-SaSortedOrdinal($Items) {
  $a = [string[]]@($Items)
  [Array]::Sort($a, [StringComparer]::Ordinal)
  return ,$a
}
function Get-SaLines([string]$Text) {
  # records as awk/grep see them (split on LF; no record after a final LF; CR kept)
  if ($Text.Length -eq 0) { return ,([string[]]@()) }
  $l = $Text.Split([char]"`n")
  if ($Text[$Text.Length - 1] -eq [char]"`n") {
    $r = New-Object 'string[]' ($l.Length - 1)
    [Array]::Copy($l, $r, $l.Length - 1)
    return ,$r
  }
  return ,$l
}
function Remove-SaCr([string]$S) { if ($S.Length -gt 0 -and $S[$S.Length - 1] -eq [char]"`r") { return $S.Substring(0, $S.Length - 1) }; return $S }
function Read-SaText([string]$LongPath) {
  # UTF-8 text of a file (no BOM stripping, like grep/awk); $null when unreadable
  try { $b = [IO.File]::ReadAllBytes($LongPath) } catch { return $null }
  return $Utf8.GetString($b)
}
function New-SaClassTable([string]$Chars) {
  $t = New-Object 'bool[]' 128
  foreach ($c in $Chars.ToCharArray()) { $t[[int]$c] = $true }
  return ,$t
}
function Test-SaCls($Tbl, [string]$S, [int]$I) {
  if ($I -lt 0 -or $I -ge $S.Length) { return $false }
  $c = [int]$S[$I]
  return ($c -lt 128 -and $Tbl[$c])
}
function New-SaLiteralRegex($Literals) {
  # a regex that matches where any of the literals occurs (grep -F semantics on one line):
  # literals that contain an earlier one as a prefix are dropped, the rest is a trie
  $u = New-SaSet
  foreach ($x in $Literals) { if ($null -ne $x -and ([string]$x).Length -gt 0) { [void]$u.Add([string]$x) } }
  if ($u.Count -eq 0) { return $null }
  $s = Get-SaSortedOrdinal $u
  $k = New-SaList
  $last = $null
  foreach ($x in $s) {
    if ($null -ne $last -and $x.StartsWith($last, [StringComparison]::Ordinal)) { continue }
    $k.Add($x); $last = $x
  }
  $sb = New-Object System.Text.StringBuilder
  Add-SaTrie $k.ToArray() 0 $k.Count 0 $sb
  return (New-Object System.Text.RegularExpressions.Regex($sb.ToString(), ([System.Text.RegularExpressions.RegexOptions]::Compiled -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)))
}
function Add-SaTrie($S, [int]$Lo, [int]$Hi, [int]$D, $Sb) {
  if ($Hi - $Lo -eq 1) { [void]$Sb.Append([Text.RegularExpressions.Regex]::Escape($S[$Lo].Substring($D))); return }
  # common extension of every string of the range
  $p = $D
  while ($true) {
    $c = $S[$Lo][$p]
    $all = $true
    for ($i = $Lo + 1; $i -lt $Hi; $i++) { if ($S[$i][$p] -cne $c) { $all = $false; break } }
    if (-not $all) { break }
    $p++
  }
  if ($p -gt $D) { [void]$Sb.Append([Text.RegularExpressions.Regex]::Escape($S[$Lo].Substring($D, $p - $D))) }
  [void]$Sb.Append('(?:')
  $i = $Lo
  $first = $true
  while ($i -lt $Hi) {
    $c = $S[$i][$p]
    $j = $i
    while ($j -lt $Hi -and $S[$j][$p] -ceq $c) { $j++ }
    if (-not $first) { [void]$Sb.Append('|') }
    $first = $false
    Add-SaTrie $S $i $j $p $Sb
    $i = $j
  }
  [void]$Sb.Append(')')
}
function Format-SaPad([string]$S, [int]$W, [bool]$Left) {
  # printf %-Ns / %Ns counting UTF-8 bytes, like awk in the C locale
  $n = $Utf8.GetByteCount($S)
  if ($n -ge $W) { return $S }
  if ($Left) { return $S + (New-Object string ([char]' ', ($W - $n))) }
  return (New-Object string ([char]' ', ($W - $n))) + $S
}

function Read-SaTexts($Paths, $Flags, $DomRegex, [string]$Needle) {
  # Reads files (several at once through a runspace pool: the \\wsl.localhost share is latency
  # bound). Result aligned with $Paths: the UTF-8 text when it is needed -- flag 1 always,
  # flag 2 when the domain regex matches somewhere, flag 4 when $Needle occurs --, a one-NUL
  # string for a file with a NUL byte (grep: binary file, never a line match), else $null
  # (not needed, or unreadable).
  $n = $Paths.Length
  $res = New-Object 'string[]' $n
  if ($n -eq 0) { return ,$res }
  $pat = ''
  if ($null -ne $DomRegex) { $pat = $DomRegex.ToString() }
  $work = {
    param($Paths, $Flags, [int]$Lo, [int]$Hi, [string]$Pat, [string]$Needle)
    $enc = New-Object System.Text.UTF8Encoding($false)
    $re = $null
    if ($Pat.Length -gt 0) { $re = New-Object System.Text.RegularExpressions.Regex($Pat, ([System.Text.RegularExpressions.RegexOptions]::Compiled -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)) }
    $out = New-Object 'string[]' ($Hi - $Lo)
    for ($i = $Lo; $i -lt $Hi; $i++) {
      $t = $null
      try { $t = $enc.GetString([System.IO.File]::ReadAllBytes($Paths[$i])) } catch { continue }
      if ($t.IndexOf([char]0) -ge 0) { $out[$i - $Lo] = [string][char]0; continue }
      $f = $Flags[$i]
      if (($f -band 1) -or (($f -band 2) -and $null -ne $re -and $re.IsMatch($t)) -or
          (($f -band 4) -and $Needle.Length -gt 0 -and $t.IndexOf($Needle, [StringComparison]::Ordinal) -ge 0)) { $out[$i - $Lo] = $t }
    }
    return ,$out
  }
  $nth = [Math]::Min(8, [Math]::Max(2, [Environment]::ProcessorCount))
  if ($n -lt 256) {
    $r = & $work $Paths $Flags 0 $n $pat $Needle
    [Array]::Copy($r, 0, $res, 0, $n)
    return ,$res
  }
  $pool = [RunspaceFactory]::CreateRunspacePool(1, $nth)
  $pool.Open()
  $jobs = New-Object 'System.Collections.Generic.List[object]'
  try {
    $chunk = [int][Math]::Ceiling($n / ($nth * 4))
    for ($lo = 0; $lo -lt $n; $lo += $chunk) {
      $hi = [Math]::Min($n, $lo + $chunk)
      $ps = [PowerShell]::Create()
      $ps.RunspacePool = $pool
      [void]$ps.AddScript($work.ToString()).AddArgument($Paths).AddArgument($Flags).AddArgument($lo).AddArgument($hi).AddArgument($pat).AddArgument($Needle)
      $jobs.Add(@($ps, $ps.BeginInvoke(), $lo))
    }
    foreach ($j in $jobs) {
      $r = $j[0].EndInvoke($j[1])
      $chunkRes = $r[0]
      [Array]::Copy($chunkRes, 0, $res, $j[2], $chunkRes.Length)
    }
  } finally {
    foreach ($j in $jobs) { $j[0].Dispose() }
    $pool.Close(); $pool.Dispose()
  }
  return ,$res
}

# ---- ownership by longest root (lib.awk) ---------------------------------------------------
function Get-SaOwner([string]$Name) {
  # @(root, types[], sdks[]) of the longest root that contains the dotted name, after the
  # exclude_packages of the deeper (or equal) levels; $null when no root owns it
  $o = $null
  if ($OwnCache.TryGetValue($Name, [ref]$o)) { return ,$o }
  $ex = $null
  $p = $Name
  $o = $null
  while ($p.Length -gt 0) {
    $recs = $null
    if ($RtRecs.TryGetValue($p, [ref]$recs)) {
      foreach ($r in $recs) { if ($r[0] -ceq 'ex') { if ($null -eq $ex) { $ex = New-SaSet }; [void]$ex.Add($r[1]) } }
      $ts = New-SaList; $ss = New-SaList
      foreach ($r in $recs) {
        $t = $r[0]; $s = $r[1]
        if ($t -ceq 'ex') { continue }
        if ($t -cne 'lib' -and $null -ne $ex -and $ex.Contains($s)) { continue }
        $ts.Add($t); $ss.Add($s)
      }
      if ($ts.Count -gt 0) { $o = @($p, $ts.ToArray(), $ss.ToArray()); break }
    }
    $p = Get-SaParent $p
  }
  $OwnCache[$Name] = $o
  return ,$o
}
function Get-SaOwnerSdks([string]$Name, [string]$Self) {
  # owner_sdks: space-separated SDK ids owning the name (not library roots), without $Self
  $l = $null
  if (-not $OsCache.TryGetValue($Name, [ref]$l)) {
    $o = Get-SaOwner $Name
    $lst = New-SaList
    if ($null -ne $o) {
      $ts = $o[1]; $ss = $o[2]
      for ($i = 0; $i -lt $ts.Length; $i++) {
        if ($ts[$i] -ceq 'lib') { continue }
        if (-not $lst.Contains($ss[$i])) { $lst.Add($ss[$i]) }
      }
    }
    $l = $lst.ToArray()
    $OsCache[$Name] = $l
  }
  if ($l.Length -eq 0) { return '' }
  if ($Self.Length -eq 0) { return [string]::Join(' ', $l) }
  $out = New-SaList
  foreach ($s in $l) { if ($s -cne $Self) { $out.Add($s) } }
  return [string]::Join(' ', $out.ToArray())
}
function Get-SaAliasNorm([string]$Pkg) {
  if ($AlQ.Count -eq 0) { return $Pkg }
  $p = $Pkg
  while ($p.Length -gt 0) {
    $q = $null
    if ($AlQ.TryGetValue($p, [ref]$q)) { return $q + $Pkg.Substring($p.Length) }
    $p = Get-SaParent $p
  }
  return $Pkg
}
function Get-SaRewrite([string]$Tok) {
  # arewrite: a dotted token under an aliased package P becomes Q... only when a prefix of it
  # is a class file of the aliased tree that jadx did not rename itself
  if ($AlQ.Count -eq 0) { return $Tok }
  $r = $null
  if ($RwCache.TryGetValue($Tok, [ref]$r)) { return $r }
  $p = $Tok
  $q = $null
  while ($p.Length -gt 0) { if ($AlQ.TryGetValue($p, [ref]$q)) { break }; $p = Get-SaParent $p }
  $r = $Tok
  if ($p.Length -gt 0) {
    $c = $Tok
    while ($c.Length -gt $p.Length) {
      $v = $null
      if ($AcMap.TryGetValue($c, [ref]$v) -and $v -eq 0) { $r = $q + $Tok.Substring($p.Length); break }
      $c = Get-SaParent $c
    }
  }
  $RwCache[$Tok] = $r
  return $r
}

# ---- java/kotlin/smali tokens (app.awk) ----------------------------------------------------
function Get-SaKeyOf([string]$J) {
  # Java dotted FQCN -> API key (inner classes after the first Uppercase segment joined by $)
  $a = $J.Split([char]'.')
  $sb = New-Object System.Text.StringBuilder
  $inner = $false
  for ($i = 0; $i -lt $a.Length; $i++) {
    if ($i -eq 0) { [void]$sb.Append($a[$i]) }
    elseif ($inner) { [void]$sb.Append('$').Append($a[$i]) }
    else { [void]$sb.Append('.').Append($a[$i]) }
    if ($a[$i].Length -gt 0 -and [int]$a[$i][0] -ge 65 -and [int]$a[$i][0] -le 90) { $inner = $true }
  }
  return $sb.ToString()
}
function Get-SaClsOf([string]$T) {
  # the class part of a dotted token (up to its first Uppercase segment after the first), "" if none
  $a = $T.Split([char]'.')
  for ($i = 1; $i -lt $a.Length; $i++) {
    if ($a[$i].Length -gt 0 -and [int]$a[$i][0] -ge 65 -and [int]$a[$i][0] -le 90) { return [string]::Join('.', $a, 0, $i + 1) }
  }
  return ''
}
function Test-SaUpper([string]$W) { return ($W.Length -gt 0 -and [int]$W[0] -ge 65 -and [int]$W[0] -le 90) }

function Add-SaVis([string]$Simple, [string]$Jfq, [string]$Sd) {
  if ($Simple.Length -eq 0 -or $Sd.Length -eq 0) { return }
  if (-not $VIS.ContainsKey($Simple)) { $VLIST.Add($Simple) }
  $VIS[$Simple] = $Jfq
  $VSD[$Simple] = $Sd
}
function Add-SaR([string]$Sd, [string]$Cls) {
  foreach ($s in $Sd.Split([char]' ')) {
    if ($s.Length -eq 0) { continue }
    $k = $LS.cur + $SUB + $LS.ln + $SUB + $s
    $idx = 0
    if (-not $Ev.RIDX.TryGetValue($k, [ref]$idx)) {
      $Ev.RIDX[$k] = $Ev.RR.Count
      $Ev.RR.Add($LS.cur); $Ev.RL.Add($LS.ln); $Ev.RSD.Add($s); $Ev.RK.Add($Cls)
    } elseif ((' ' + $Ev.RK[$idx] + ' ').IndexOf(' ' + $Cls + ' ', [StringComparison]::Ordinal) -lt 0) {
      $Ev.RK[$idx] = $Ev.RK[$idx] + ' ' + $Cls
    }
    $LS.evn++
  }
}
function Add-SaC([string]$K, [string]$M, [string]$Conf) {
  $rs = $APIR[$K + $SUB + $M]
  foreach ($x in $rs.Split([char]' ')) {
    if ($x.Length -eq 0) { continue }
    $c = $x.IndexOf([char]':')
    $role = $x.Substring(0, $c); $sdk = $x.Substring($c + 1)
    $api = $K + '#' + $M
    $key = $LS.cur + $SUB + $LS.ln + $SUB + $sdk + $SUB + $role + $SUB + $api
    $idx = 0
    if ($Ev.CSEEN.TryGetValue($key, [ref]$idx)) {
      if ($Conf -ceq 'exact') { $Ev.CF[$idx] = 'exact' }
    } else {
      $Ev.CSEEN[$key] = $Ev.CRl.Count
      $Ev.CRl.Add($LS.cur); $Ev.CLn.Add($LS.ln); $Ev.CS.Add($sdk); $Ev.CRo.Add($role); $Ev.CA.Add($api); $Ev.CF.Add($Conf)
    }
    $LS.evn++
  }
}
function Get-SaResolve([string]$Chain) {
  # @(api key or '', resolved): the class the chain names (FQCN, or a visible simple name
  # followed by inner class names); resolved = the chain names an SDK class at all
  $f = $Chain; $rest = ''
  $d = $Chain.IndexOf([char]'.')
  if ($d -ge 0) { $f = $Chain.Substring(0, $d); $rest = $Chain.Substring($d + 1) }
  $v = $null
  if ($VIS.TryGetValue($f, [ref]$v)) {
    $k = Get-SaKeyOf $v
    if ($rest.Length -gt 0) { $k = $k + '$' + $rest.Replace('.', '$') }
    if ($APIC.Contains($k)) { return ,@($k, $true) }
    return ,@('', $true)
  }
  if ($rest.Length -gt 0 -and $f.Length -gt 0 -and [int]$f[0] -ge 97 -and [int]$f[0] -le 122) {
    $c = Get-SaRewrite $Chain
    $k = Get-SaKeyOf $c
    if ($APIC.Contains($k)) { return ,@($k, $true) }
    if ((Get-SaOwnerSdks $c '').Length -gt 0 -and (Get-SaClsOf $c).Length -gt 0) { return ,@('', $true) }
  }
  return ,@('', $false)
}
function Invoke-SaInstance([string]$M) {
  foreach ($simple in $VLIST) {
    $ok = Get-SaKeyOf $VIS[$simple]
    $outs = $null
    if (-not $OUTERS.TryGetValue($ok, [ref]$outs)) { continue }
    foreach ($kk in $outs) { if ($APIR.ContainsKey($kk + $SUB + $M)) { Add-SaC $kk $M 'import-scoped' } }
  }
}
function Invoke-SaWildRef([string]$W) {
  foreach ($p in $FW) {
    $c = $p + '.' + $W
    if (-not ($WildCls.Contains($c) -or $OUTERS.ContainsKey($c))) { continue }
    $sd = Get-SaOwnerSdks $c $LS.self
    if ($sd.Length -eq 0) { continue }
    Add-SaVis $W $c $sd
    Add-SaR $sd (Get-SaKeyOf $c)
    return
  }
}
function Split-SaImport([string]$S) {
  # import line -> @(name, asname): import/static stripped, ";..." cut, Kotlin "as", blanks removed
  $S = $ReImpHead.Replace($S, '', 1)
  $S = $ReStatic.Replace($S, '', 1)
  $S = $ReSemi.Replace($S, '', 1)
  $asn = ''
  $m = $ReAs.Match($S)
  if ($m.Success) { $asn = $S.Substring($m.Index + $m.Length); $S = $S.Substring(0, $m.Index) }
  $S = $S.Replace(' ', '').Replace("`t", '')
  return ,@($S, $asn)
}
function Invoke-SaJavaImport([string]$S) {
  $x = Split-SaImport $S
  $s = $x[0]; $asn = $x[1]
  if ($s.EndsWith('.*', [StringComparison]::Ordinal)) {
    $s = Get-SaRewrite $s.Substring(0, $s.Length - 2)
    if ($WILD.Contains($s) -and -not $FWSET.Contains($s)) { [void]$FWSET.Add($s); $FW.Add($s) }
    return
  }
  $s = Get-SaRewrite $s
  $sd = Get-SaOwnerSdks $s $LS.self
  if ($sd.Length -eq 0) { return }
  $c = Get-SaClsOf $s
  if ($c.Length -eq 0) { $c = $s }
  Add-SaVis (Get-SaLastSeg $c) $c $sd
  if ($asn.Length -gt 0) { Add-SaVis $asn $c $sd }
}
function Invoke-SaJavaLine([string]$S, [string]$Ext) {
  if ($ReImportLine.IsMatch($S)) { Invoke-SaJavaImport $S; return }
  if ($RePackageLine.IsMatch($S)) { return }
  # dotted tokens: FQCN references (and inline FQCNs become visible)
  foreach ($m in $ReTok.Matches($S)) {
    if ($m.Index -gt 0 -and $S[$m.Index - 1] -eq [char]'.') { continue }
    $t2 = Get-SaRewrite $m.Value
    $ck = $t2 + $SUB + $LS.self
    $sd = $null
    if (-not $OsSelfCache.TryGetValue($ck, [ref]$sd)) { $sd = Get-SaOwnerSdks $t2 $LS.self; $OsSelfCache[$ck] = $sd }
    if ($sd.Length -eq 0) { continue }
    $cls = Get-SaClsOf $t2
    if ($cls.Length -gt 0) { Add-SaVis (Get-SaLastSeg $cls) $cls $sd; Add-SaR $sd (Get-SaKeyOf $cls) } else { Add-SaR $sd '-' }
  }
  # simple names of visible SDK classes (whole words)
  foreach ($m in $ReWord.Matches($S)) {
    $w = $m.Value
    $v = $null
    if ($VIS.TryGetValue($w, [ref]$v)) { Add-SaR $VSD[$w] (Get-SaKeyOf $v) }
    elseif ($FW.Count -gt 0 -and (Test-SaUpper $w)) { Invoke-SaWildRef $w }
  }
  # calls: .method(
  foreach ($m in $ReCall.Matches($S)) {
    $mn = $m.Value.Substring(1, $m.Value.Length - 2)
    if (-not $APIM.Contains($mn)) { continue }
    $j = $m.Index - 1
    while ($j -ge 0 -and (Test-SaCls $CIdentDot $S $j)) { $j-- }
    $chain = $S.Substring($j + 1, $m.Index - $j - 1)
    if ($chain.Length -gt 0 -and $chain[0] -ne [char]'.' -and -not ([int]$chain[0] -ge 48 -and [int]$chain[0] -le 57)) {
      $rv = Get-SaResolve $chain
      $k = $rv[0]
      if ($k.Length -gt 0 -and $APIR.ContainsKey($k + $SUB + $mn)) { Add-SaC $k $mn 'exact'; continue }
      if ($rv[1]) { continue }
    }
    if ($m.Index -gt 0) {
      $pc = $S[$m.Index - 1]
      if ($pc -eq [char]']' -or $pc -eq [char]')' -or (Test-SaCls $CIdent $S ($m.Index - 1))) { Invoke-SaInstance $mn }
    }
  }
  # constructors: new X( / new Outer.Inner(  (Kotlin: X( without new)
  foreach ($m in $ReNew.Matches($S)) {
    if (Test-SaCls $CIdentDot $S ($m.Index - 1)) { continue }
    $seg = $m.Value.Substring(3).TrimStart([char]' ', [char]"`t")
    $seg = $seg.Substring(0, $seg.Length - 1).TrimEnd([char]' ', [char]"`t")
    $rv = Get-SaResolve $seg
    $k = $rv[0]
    if ($k.Length -gt 0 -and $APIR.ContainsKey($k + ($SUB + '<init>'))) { Add-SaC $k '<init>' 'exact' }
  }
  if ($Ext -ceq 'kt') {
    foreach ($m in $ReKt.Matches($S)) {
      if (Test-SaCls $CIdentDot $S ($m.Index - 1)) { continue }
      $seg = $m.Value.Substring(0, $m.Value.Length - 1)
      if (-not (Test-SaUpper (Get-SaLastSeg $seg))) { continue }
      $rv = Get-SaResolve $seg
      $k = $rv[0]
      if ($k.Length -gt 0 -and $APIR.ContainsKey($k + ($SUB + '<init>'))) { Add-SaC $k '<init>' 'exact' }
    }
  }
}
function Invoke-SaSmaliLine([string]$S) {
  foreach ($m in $ReSmali.Matches($S)) {
    $cls = $m.Value.Substring(1, $m.Value.Length - 2).Replace('/', '.')
    $ck = $cls + $SUB + $LS.self
    $sd = $null
    if (-not $OsSelfCache.TryGetValue($ck, [ref]$sd)) { $sd = Get-SaOwnerSdks $cls $LS.self; $OsSelfCache[$ck] = $sd }
    if ($sd.Length -gt 0) { Add-SaR $sd $cls }
    $after = $m.Index + $m.Length
    if ($after + 1 -lt $S.Length -and $S[$after] -eq [char]'-' -and $S[$after + 1] -eq [char]'>') {
      $e = $S.IndexOf([char]'(', $after)
      if ($e -ge 0 -and ($e - $after) -gt 2) {
        $mn = $S.Substring($after + 2, $e - $after - 2)
        if ($APIR.ContainsKey($cls + $SUB + $mn)) { Add-SaC $cls $mn 'exact' }
      }
    }
  }
}
function Test-SaTokMatch([string]$S, [string]$T, [string]$Mt) {
  # method: token + "(" with a non-identifier char before; word: non-identifier chars around
  $from = 0
  while ($true) {
    $i = $S.IndexOf($T, $from, [StringComparison]::Ordinal)
    if ($i -lt 0) { return $false }
    if (-not (Test-SaCls $CIdent $S ($i - 1))) {
      $ai = $i + $T.Length
      if ($Mt -ceq 'method' -and $ai -lt $S.Length -and $S[$ai] -eq [char]'(') { return $true }
      if ($Mt -ceq 'word' -and -not (Test-SaCls $CIdent $S $ai)) { return $true }
      if ($Mt -ceq 'exact' -and $S -ceq $T) { return $true }
    }
    $from = $i + 1
  }
}
function Invoke-SaHints([string]$S) {
  $done = $null
  foreach ($h in $AppHints) {
    $id = $h[0]
    if ($null -ne $done -and $done.Contains($id)) { continue }
    $t = $h[1]
    if ($S.IndexOf($t, [StringComparison]::Ordinal) -lt 0) { continue }
    if ($h[2] -ceq 'literal' -or (Test-SaTokMatch $S $t $h[2])) {
      if ($null -eq $done) { $done = New-SaSet }
      [void]$done.Add($id)
      $Ev.HER.Add($LS.cur); $Ev.HEL.Add($LS.ln); $Ev.HEI.Add($id)
      $LS.evn++
    }
  }
}
function Test-SaHost([string]$S, [string]$D) {
  # a host or a registrable suffix: no host character before it ("." allowed: a subdomain),
  # and no host character after it
  $from = 0
  while ($true) {
    $i = $S.IndexOf($D, $from, [StringComparison]::Ordinal)
    if ($i -lt 0) { return $false }
    $ai = $i + $D.Length
    if (-not (Test-SaCls $CHost $S ($i - 1)) -and -not (Test-SaCls $CHost $S $ai) -and
        -not ($ai -lt $S.Length -and $S[$ai] -eq [char]'.' -and (Test-SaCls $CAlnum $S ($ai + 1)))) { return $true }
    $from = $i + 1
  }
}
function Get-SaDomHits([string]$Text) {
  # dom.awk on one file: @(line, kind E|I, sdk, value, text) records, line order
  if ($null -eq $ReDom -or -not $ReDom.IsMatch($Text)) { return $null }
  $out = New-SaOList
  $lines = Get-SaLines $Text
  for ($i = 0; $i -lt $lines.Length; $i++) {
    if (-not $ReDom.IsMatch($lines[$i])) { continue }
    $s = Remove-SaCr $lines[$i]
    $ln = [string]($i + 1)
    foreach ($d in $DomList) {
      if ($s.IndexOf($d[1], [StringComparison]::Ordinal) -ge 0 -and (Test-SaHost $s $d[1])) { $out.Add(@($ln, 'E', $d[0], $d[1], $s)) }
    }
    foreach ($d in $IdpList) {
      if ($s.IndexOf($d[1], [StringComparison]::Ordinal) -ge 0) { $out.Add(@($ln, 'I', $d[0], $d[1], $s)) }
    }
  }
  return ,$out
}

# ---- the engine ----------------------------------------------------------------------------
function Invoke-SaCore {
  param([string]$Tool, [object[]]$Argv, [string]$Here, $Holder)
  $ErrorActionPreference = 'Stop'
  Set-StrictMode -Version 2.0
  $Utf8 = New-Object System.Text.UTF8Encoding($false)
  $SUB = [string][char]0x1c
  if ($Tool -ceq 'find-trackers') { $toolTitle = 'Tracker'; $aspects = @('generic', 'endpoints', 'manifest', 'entrypoints'); $wrapper = 'find-trackers.ps1' }
  elseif ($Tool -ceq 'find-ads') { $toolTitle = 'Ad'; $aspects = @('formats', 'mediation', 'consent', 'manifest', 'entrypoints'); $wrapper = 'find-ads.ps1' }
  else { Write-SaErr 'sdk-audit: internal error: -Tool must be find-trackers or find-ads'; Stop-Sa 1 }

  # ---- arguments ----------------------------------------------------------------------------
  $selAll = $true; $selFlags = New-SaList; $selSdks = New-SaList; $selAsp = New-SaList; $filters = $false
  $outSummary = $false; $outTsv = $false; $outJson = $false
  $inArg = ''; $manifestPath = ''; $registry = ''; $listMode = $false; $full = $false; $noHints = $false
  $endopts = $false
  $av = @()
  if ($null -ne $Argv) { $av = @($Argv | ForEach-Object { if ($null -eq $_) { '' } else { [string]$_ } }) }
  $dieUsage = {
    param([string]$Msg)
    Write-SaErr ('Error: ' + $Msg); Write-SaErr ''
    [Console]::Error.Write((Get-SdkAuditUsage $Tool) + "`n")
    Stop-Sa 1
  }
  for ($i = 0; $i -lt $av.Count; $i++) {
    $a = $av[$i]
    if ($endopts) { $inArg = $a; continue }
    if ($a -ceq '--') { $endopts = $true; continue }
    if (-not $a.StartsWith('-', [StringComparison]::Ordinal)) { $inArg = $a; continue }
    # in-process, PowerShell hands a one-dash -name:value over as '-name:' and 'value'
    if ($a.Length -gt 2 -and $a[1] -ne [char]'-' -and $a.EndsWith(':', [StringComparison]::Ordinal) -and $a.IndexOfAny([char[]]@([char]':', [char]'=')) -eq $a.Length - 1) {
      $a = $a.Substring(0, $a.Length - 1)
    }
    $name = $a; $val = ''; $hasval = $false
    $ci = $a.IndexOfAny([char[]]@([char]':', [char]'='))
    if ($ci -ge 0) { $name = $a.Substring(0, $ci); $val = $a.Substring($ci + 1); $hasval = $true }
    $n = ConvertTo-RegistryAsciiLower ($name.Replace('-', ''))
    if ($n -ceq 'sdk' -or $n -ceq 'manifestpath' -or $n -ceq 'registry') {
      if (-not $hasval) {
        if ($i + 1 -ge $av.Count) { & $dieUsage ('option ' + $name + ' requires a value') }
        $i++; $val = $av[$i]
      }
      if ($val.Length -eq 0) { & $dieUsage ('option ' + $name + ' requires a value') }
      if ($n -ceq 'sdk') { foreach ($x in (Split-SaWs $val)) { $selSdks.Add($x) }; $selAll = $false; $filters = $true }
      elseif ($n -ceq 'manifestpath') { $manifestPath = $val }
      else { $registry = $val }
      continue
    }
    if ($hasval) { & $dieUsage ('option ' + $name + ' takes no value') }
    switch -CaseSensitive ($n) {
      'h' { $Holder.Out = Get-SdkAuditUsage $Tool; Stop-Sa 0 }
      'help' { $Holder.Out = Get-SdkAuditUsage $Tool; Stop-Sa 0 }
      'all' { $selAll = $true }
      'summary' { $outSummary = $true }
      'tsv' { $outTsv = $true }
      'json' { $outJson = $true }
      'listsdks' { $listMode = $true }
      'full' { $full = $true }
      'nohints' { $noHints = $true }
      '' { & $dieUsage ('unknown option: ' + $a) }
      default {
        if ($aspects -ccontains $n) { $selAsp.Add($n); $selAll = $false; $filters = $true }
        elseif ($n -cmatch '[^a-z0-9]') { & $dieUsage ('unknown option: ' + $a) }
        else { $selFlags.Add($n); $selAll = $false; $filters = $true }
      }
    }
  }

  $dFull = ''
  if (-not $listMode) {
    if ($inArg.Length -eq 0) { & $dieUsage 'no input directory specified' }
    $ok = $false
    try { $dFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($inArg); $ok = [IO.Directory]::Exists((Get-LongPath $dFull)) } catch { $ok = $false }
    if (-not $ok) { Write-SaErr ('Error: Directory not found: ' + $inArg); Stop-Sa 1 }
  }
  $manFull = ''
  if ($manifestPath.Length -gt 0) {
    $ok = $false
    try { $manFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($manifestPath); $ok = [IO.File]::Exists((Get-LongPath $manFull)) } catch { $ok = $false }
    if (-not $ok) { Write-SaErr ('Error: manifest not found: ' + $manifestPath); Stop-Sa 1 }
  }

  # ---- registry -------------------------------------------------------------------------------
  $regDir = Resolve-RegistryDir -Registry $registry -DefaultDir (Join-Path (Split-Path -Parent $Here) 'registry')
  $rq = Get-RegistryRows -Registry $regDir
  foreach ($m in $rq.Messages) { Write-SaErr $m }
  if ($rq.ExitCode -ne 0) { Write-SaErr 'Error: cannot read the SDK registry'; Stop-Sa 1 }
  $rqs = Get-RegistryShared -Registry $regDir
  foreach ($m in $rqs.Messages) { Write-SaErr $m }
  if ($rqs.ExitCode -ne 0) { Write-SaErr 'Error: cannot read the SDK registry'; Stop-Sa 1 }

  # ---- plan (plan.awk) ------------------------------------------------------------------------
  $ingroup = New-SaSet
  $legacy = New-SaOList            # @(flag, sdk, label, prefix)
  $lrank = New-SaIDict; $lflag = New-SaSDict; $llabel = New-SaSDict; $lpre = New-SaSDict
  $rolesL = New-SaOList            # @(role, label)
  $sep = ''
  $fmtL = New-SaOList              # @(kind, token, format)
  $rootsL = New-SaOList            # @(root, type, sdk) in roots.tsv order
  $hidL = New-SaList; $htool = New-SaSDict; $hflag = New-SaSDict; $hscope = New-SaSDict; $hmatch = New-SaSDict; $htitle = New-SaSDict
  $tokL = New-SaOList              # @(id, token)
  foreach ($it in $rqs.Items) {
    $k1 = ConvertTo-RegistryTsvField $it.Kind; $k2 = ConvertTo-RegistryTsvField $it.Key; $k3 = ConvertTo-RegistryTsvField $it.Value
    if ($k1 -ceq 'tool_group') { if ($k2 -ceq $Tool) { [void]$ingroup.Add($k3) } }
    elseif ($k1 -ceq 'legacy_flag') {
      if ($k2 -ceq $Tool) {
        $a = Split-SaWs $k3
        $pre = ''
        for ($j = 3; $j -lt $a.Length; $j++) { if ($j -gt 3) { $pre += ' ' }; $pre += $a[$j] }
        $f0 = Get-SaAt $a 0; $s0 = Get-SaAt $a 1; $l0 = Get-SaAt $a 2
        $legacy.Add(@($f0, $s0, $l0, $pre))
        $lrank[$s0] = $legacy.Count; $lflag[$s0] = $f0; $llabel[$s0] = $l0; $lpre[$s0] = $pre
      }
    }
    elseif ($k1 -ceq 'role_label') { $rolesL.Add(@($k2, $k3)) }
    elseif ($k1 -ceq 'section_separator') { $sep = $k3 }
    elseif ($k1 -ceq 'format_token') { $a = Split-SaWs $k3; $fmtL.Add(@($k2, (Get-SaAt $a 0), (Get-SaAt $a 1))) }
    elseif ($k1 -ceq 'library_root') { $rootsL.Add(@($k3, 'lib', '-')) }
    elseif ($k1 -ceq 'hint_meta') {
      $a = Split-SaWs $k3
      $hid = Get-SaAt $a 0
      $hidL.Add($hid); $htool[$hid] = Get-SaAt $a 1; $hflag[$hid] = Get-SaAt $a 2; $hscope[$hid] = Get-SaAt $a 3; $hmatch[$hid] = Get-SaAt $a 4
    }
    elseif ($k1 -ceq 'hint_title') { $htitle[$k2] = $k3 }
    elseif ($k1 -ceq 'hint_token') { $tokL.Add(@($k2, $k3)) }
  }
  $ids = New-SaList; $cat = New-SaSDict; $dispName = New-SaSDict; $grp = New-SaSDict; $inh = New-SaSet; $tgt = New-SaSDict
  $pk = New-SaSDict; $xp = New-SaSDict; $pkL = New-SaOList
  $markersL = New-SaOList; $mcompsL = New-SaOList; $mnamesL = New-SaOList; $domainsL = New-SaOList; $idpfxL = New-SaOList
  $apiL = New-SaOList; $seenapi = New-SaSet
  foreach ($it in $rq.Items) {
    $s = ConvertTo-RegistryTsvField $it.SdkId; $f = ConvertTo-RegistryTsvField $it.Field; $v = ConvertTo-RegistryTsvField $it.Value
    if (-not $cat.ContainsKey($s)) { $ids.Add($s); $cat[$s] = ConvertTo-RegistryTsvField $it.Category }
    switch -CaseSensitive ($f) {
      'display_name' { $dispName[$s] = $v }
      'group' { $grp[$s] = $v }
      'in_house_wrapper' { if ($v -ceq 'true') { [void]$inh.Add($s) } else { [void]$inh.Remove($s) } }
      'has_targets' { $tgt[$s] = $v }
      'package' { if ($pk.ContainsKey($s)) { $pk[$s] = $pk[$s] + ' ' + $v } else { $pk[$s] = $v }; $pkL.Add(@($s, $v)) }
      'extra_package' { if ($xp.ContainsKey($s)) { $xp[$s] = $xp[$s] + ' ' + $v } else { $xp[$s] = $v }; $pkL.Add(@($s, $v)) }
      'exclude_package' { $rootsL.Add(@($v, 'ex', $s)) }
      'namespace_root' { $rootsL.Add(@($v, 'ns', $s)) }
      'adapter_package' { $rootsL.Add(@($v, 'ad', $s)) }
      'marker_class' { $markersL.Add(@($s, $v)) }
      'manifest_component' { $mcompsL.Add(@($s, $v)) }
      'manifest_name' { $mnamesL.Add(@($s, $v)) }
      'domain' { $domainsL.Add(@($s, $v)) }
      'id_prefix' { $a = Split-SaWs $v; $idpfxL.Add(@($s, (Get-SaAt $a 0), (Get-SaAt $a 1))) }
      { $_ -ceq 'target_api' -or $_ -ceq 'api' } {
        $a = Split-SaWs $v
        $role = Get-SaAt $a 2
        if ($f -ceq 'target_api') { if ($role -ceq 'entry_point') { $role = 'init' } else { $role = 'ad_operation' } }
        $key = (Get-SaAt $a 0) + $SUB + (Get-SaAt $a 1) + $SUB + $role + $SUB + $s
        if ($seenapi.Add($key)) { $apiL.Add(@((Get-SaAt $a 0), (Get-SaAt $a 1), $role, $s)) }
      }
    }
  }
  foreach ($x in $pkL) { if ($inh.Contains($x[0])) { $rootsL.Add(@($x[1], 'inh', $x[0])) } else { $rootsL.Add(@($x[1], 'id', $x[0])) } }
  # entries: legacy rows first (legacy_flags order), then sdk_id (ordinal)
  $entKeys = New-SaList
  $entByKey = New-SaDict
  foreach ($s in $ids) {
    $g = ''; if ($grp.ContainsKey($s)) { $g = $grp[$s] }
    $d0 = ''; if ($dispName.ContainsKey($s)) { $d0 = $dispName[$s] }
    $rk = 1000; if ($lrank.ContainsKey($s)) { $rk = $lrank[$s] }
    $e = @{
      Id = $s; Cat = $cat[$s]; Grp = $g; Disp = $d0; Inh = $inh.Contains($s)
      Tgt = ($tgt.ContainsKey($s) -and $tgt[$s] -ceq 'true'); Ing = $ingroup.Contains($g); Rank = $rk
      Flag = $(if ($lflag.ContainsKey($s)) { $lflag[$s] } else { '-' })
      Label = $(if ($llabel.ContainsKey($s)) { $llabel[$s] } else { '-' })
      Pre = $(if ($lpre.ContainsKey($s)) { $lpre[$s] } else { $d0 })
      Pk = $(if ($pk.ContainsKey($s) -and $pk[$s].Length -gt 0) { $pk[$s] } else { '-' })
      Xp = $(if ($xp.ContainsKey($s) -and $xp[$s].Length -gt 0) { $xp[$s] } else { '-' })
    }
    $key = $rk.ToString('D9') + "`0" + $s
    $entKeys.Add($key); $entByKey[$key] = $e
  }
  $ents = New-SaOList
  foreach ($key in (Get-SaSortedOrdinal $entKeys)) { $ents.Add($entByKey[$key]) }
  $entById = New-SaDict
  foreach ($e in $ents) { $entById[$e.Id] = $e }
  $hintsL = New-SaOList            # hints.tsv: @(id, flag, scope, match, title) of this tool
  foreach ($id in $hidL) {
    if ($htool[$id] -cne $Tool) { continue }
    $t0 = ''; if ($htitle.ContainsKey($id)) { $t0 = $htitle[$id] }
    $hintsL.Add(@($id, $hflag[$id], $hscope[$id], $hmatch[$id], $t0))
  }
  $htokL = New-SaOList             # htok.tsv: @(id, token, match, scope)
  foreach ($x in $tokL) {
    $tt = ''; if ($htool.ContainsKey($x[0])) { $tt = $htool[$x[0]] }
    if ($tt -ceq $Tool) { $htokL.Add(@($x[0], $x[1], $hmatch[$x[0]], $hscope[$x[0]])) }
  }

  # ---- SDK flags / --sdk ------------------------------------------------------------------------
  $selIds = New-SaSet
  foreach ($f in $selFlags) {
    $id = $null
    foreach ($x in $legacy) { if ($x[0] -ceq $f) { $id = $x[1]; break } }
    if ($null -eq $id) { & $dieUsage ('unknown option: --' + $f) }
    [void]$selIds.Add($id)
  }
  foreach ($id in $selSdks) {
    if (-not $entById.ContainsKey($id)) { Write-SaErr ("Error: unknown SDK '" + $id + "' (see " + $wrapper + ' --list-sdks)'); Stop-Sa 1 }
    $e = $entById[$id]
    if ($e.Ing) { [void]$selIds.Add($id) }
    else {
      if ($e.Grp -ceq 'trackers') { Write-SaErr ("Error: '" + $id + "' is a find-trackers SDK") }
      elseif ($e.Grp -ceq 'ads' -or $e.Grp -ceq 'consent') { Write-SaErr ("Error: '" + $id + "' is a find-ads SDK") }
      else { Write-SaErr ("Error: '" + $id + "' is not a " + $Tool + ' SDK (group ' + $e.Grp + ')') }
      Stop-Sa 1
    }
  }

  if ($listMode) {
    $rows = New-SaList
    foreach ($e in $ents) {
      if (-not $e.Ing) { continue }
      $lf = '-'; if ($e.Flag -cne '-') { $lf = '--' + $e.Flag }
      $nz = 'no'; if ($e.Tgt) { $nz = 'yes' }
      $rows.Add($e.Id + "`t" + $e.Cat + "`t" + $lf + "`t" + $nz + "`t" + $e.Pk + "`t" + $e.Xp)
    }
    $out = New-SaList
    # packages = the entry's .packages (neutralized when neutralizable=yes);
    # audit_only_packages = detection.extra_packages (identity for the audit only, NEVER neutralized)
    $out.Add("sdk_id`tcategory`tlegacy_flag`tneutralizable`tpackages`taudit_only_packages")
    foreach ($r in (Get-SaSortedOrdinal $rows)) { $out.Add($r) }
    $Holder.Out = [string]::Join("`n", $out.ToArray())
    return
  }

  $mode = 'text'
  if ($outJson) { $mode = 'json' } elseif ($outTsv) { $mode = 'tsv' } elseif ($outSummary) { $mode = 'summary' }
  if ($mode -cne 'text' -and $filters) { Write-SaErr ('[INFO] --' + $mode + ' reports the whole ' + $Tool + ' group of the registry: SDK and aspect filters are ignored') }

  # ---- input layout (DESIGN 5.3) --------------------------------------------------------------
  $DISP = $inArg
  while ($DISP.Length -gt 1 -and ($DISP.EndsWith('/', [StringComparison]::Ordinal) -or $DISP.EndsWith('\', [StringComparison]::Ordinal))) {
    $t = $DISP.Substring(0, $DISP.Length - 1)
    if ($t.EndsWith(':', [StringComparison]::Ordinal)) { break }
    $DISP = $t
  }
  $dFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DISP)
  $dLong = Get-LongPath $dFull
  # $dLong names the directory (a drive or share root keeps its trailing '\': '\\?\Q:' without it
  # is the volume, not its root directory); $dBase never ends with '\' and is the prefix that
  # paths are built on (the \\?\ prefix turns normalization off, so '\\' would not resolve).
  $dBase = $dLong.TrimEnd([char]'\')
  # the printed paths: no doubled separator after a root input such as 'Q:\'
  $DSEP = '\'
  if ($DISP.EndsWith('\', [StringComparison]::Ordinal) -or $DISP.EndsWith('/', [StringComparison]::Ordinal)) { $DSEP = '' }
  $coderoots = New-SaList
  $MAN = ''; $MANDISP = ''; $LAYOUT = ''
  $smali = New-SaList
  foreach ($d in [IO.Directory]::GetDirectories($dLong)) {
    $nm = [IO.Path]::GetFileName($d)
    if ($nm.StartsWith('smali', [StringComparison]::Ordinal) -and $nm -cne 'smali_assets') { $smali.Add($nm) }
  }
  $baseName = [IO.Path]::GetFileName($dFull.TrimEnd([char]'\', [char]'/'))
  if ([IO.File]::Exists($dBase + '\AndroidManifest.xml') -and $smali.Count -gt 0) {
    $LAYOUT = 'apktool'
    foreach ($x in (Get-SaSortedOrdinal $smali)) { $coderoots.Add($x) }
    $MAN = $dBase + '\AndroidManifest.xml'; $MANDISP = $DISP + $DSEP + 'AndroidManifest.xml'
  } elseif ([IO.Directory]::Exists($dBase + '\sources')) {
    $LAYOUT = 'jadx'
    $coderoots.Add('sources')
    if ([IO.File]::Exists($dBase + '\resources\AndroidManifest.xml')) { $MAN = $dBase + '\resources\AndroidManifest.xml'; $MANDISP = $DISP + $DSEP + 'resources\AndroidManifest.xml' }
  } elseif ($baseName -ceq 'sources' -and [IO.File]::Exists((Get-LongPath ($dFull + '\..\resources\AndroidManifest.xml')))) {
    $LAYOUT = 'jadx-sources'
    $coderoots.Add('')
    $MAN = Get-LongPath ($dFull + '\..\resources\AndroidManifest.xml'); $MANDISP = $DISP + '\..\resources\AndroidManifest.xml'
  } else {
    $splits = New-SaList
    foreach ($d in [IO.Directory]::GetDirectories($dLong)) {
      $nm = [IO.Path]::GetFileName($d)
      if ($nm.StartsWith('.', [StringComparison]::Ordinal)) { continue }
      if ([IO.Directory]::Exists($d + '\sources')) { $splits.Add($nm) }
    }
    if ($splits.Count -gt 0) {
      $LAYOUT = 'jadx-xapk'
      $first = ''; $base = ''
      foreach ($sp in (Get-SaSortedOrdinal $splits)) {
        $coderoots.Add($sp + '/sources')
        $m = $dBase + '\' + $sp + '\resources\AndroidManifest.xml'
        if ($base.Length -gt 0 -or -not [IO.File]::Exists($m)) { continue }
        if ($first.Length -eq 0) { $first = $sp }
        $on = $false; $hasSplit = $false
        $mt = Read-SaText $m
        if ($null -ne $mt) {
          foreach ($l in (Get-SaLines $mt)) {
            if ($l.IndexOf('<manifest', [StringComparison]::Ordinal) -ge 0) { $on = $true }
            if ($on -and $l.IndexOf('split=', [StringComparison]::Ordinal) -ge 0) { $hasSplit = $true }
            if ($on -and $l.IndexOf('>', [StringComparison]::Ordinal) -ge 0) { break }
          }
        }
        if (-not $hasSplit) { $base = $sp }
      }
      if ($base.Length -eq 0) { $base = $first }
      if ($base.Length -gt 0) { $MAN = $dBase + '\' + $base + '\resources\AndroidManifest.xml'; $MANDISP = $DISP + $DSEP + $base + '\resources\AndroidManifest.xml' }
    } else {
      $LAYOUT = 'tree'
      $coderoots.Add('')
      if ([IO.File]::Exists($dBase + '\AndroidManifest.xml')) { $MAN = $dBase + '\AndroidManifest.xml'; $MANDISP = $DISP + $DSEP + 'AndroidManifest.xml' }
    }
  }
  if ($manifestPath.Length -gt 0) { $MAN = Get-LongPath $manFull; $MANDISP = $manifestPath }
  Write-SaErr ('[INFO] layout: ' + $LAYOUT)
  foreach ($r in $coderoots) { if ($r.Length -eq 0) { Write-SaErr ('[INFO] code root: ' + $DISP) } else { Write-SaErr ('[INFO] code root: ' + $DISP + $DSEP + $r.Replace('/', '\')) } }
  if ($MAN.Length -gt 0) { Write-SaErr ('[INFO] manifest: ' + $MANDISP) } else { Write-SaErr '[INFO] # manifest: not found (use --manifest-path)' }
  $JADX = $LAYOUT.StartsWith('jadx', [StringComparison]::Ordinal)
  $pathOf = { param([string]$Rel) if ($Rel.Length -eq 0) { return $DISP }; return $DISP + $DSEP + $Rel.Replace('/', '\') }

  # ---- manifest (man.awk) -----------------------------------------------------------------------
  $DECL = New-SaSet
  foreach ($x in @('activity', 'activity-alias', 'service', 'receiver', 'provider', 'meta-data', 'uses-permission', 'permission', 'action')) { [void]$DECL.Add($x) }
  $MNL = New-SaList; $MNT = New-SaList; $MNV = New-SaList   # N records
  $MTXT = New-SaSDict                                         # L records: line -> text
  $APPPKG = ''
  if ($MAN.Length -gt 0) {
    $mt = Read-SaText $MAN
    if ($null -eq $mt) { Write-SaErr ('Error: cannot read the manifest: ' + $MANDISP); Stop-Sa 1 }
    $reTag = New-Object System.Text.RegularExpressions.Regex('^[A-Za-z][A-Za-z0-9_.:-]*', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    $tag = ''; $pkgname = ''
    $mlines = Get-SaLines $mt
    for ($li = 0; $li -lt $mlines.Length; $li++) {
      $line = Remove-SaCr $mlines[$li]
      $nr = [string]($li + 1)
      $s = $line; $named = $false
      while ($true) {
        $lt = $s.IndexOf([char]'<')
        $nmi = $s.IndexOf('android:name="', [StringComparison]::Ordinal)
        $pki = -1
        if ($tag -ceq 'manifest' -or $s.IndexOf('<manifest', [StringComparison]::Ordinal) -ge 0) { $pki = $s.IndexOf('package="', [StringComparison]::Ordinal) }
        $nxt = -1; $what = ''
        if ($lt -ge 0) { $nxt = $lt; $what = 'tag' }
        if ($nmi -ge 0 -and ($nxt -lt 0 -or $nmi -lt $nxt)) { $nxt = $nmi; $what = 'name' }
        if ($pki -ge 0 -and ($nxt -lt 0 -or $pki -lt $nxt)) { $nxt = $pki; $what = 'pkg' }
        if ($nxt -lt 0) { break }
        if ($what -ceq 'tag') {
          $r = $s.Substring($lt + 1)
          $mm = $reTag.Match($r)
          if ($mm.Success) { $tag = $mm.Value } else { $tag = '' }
          $s = $r; continue
        }
        if ($what -ceq 'pkg') {
          $r = $s.Substring($pki + 9); $e = $r.IndexOf([char]'"')
          if ($e -ge 0 -and $tag -ceq 'manifest' -and $pkgname.Length -eq 0) { $pkgname = $r.Substring(0, $e); if ($APPPKG.Length -eq 0) { $APPPKG = $pkgname } }
          if ($e -ge 0) { $s = $r.Substring($e + 1) } else { $s = '' }
          continue
        }
        $r = $s.Substring($nmi + 14); $e = $r.IndexOf([char]'"')
        if ($e -lt 0) { break }
        $v = $r.Substring(0, $e)
        if ($v.StartsWith('.', [StringComparison]::Ordinal) -and $pkgname.Length -gt 0) { $v = $pkgname + $v }
        if ($DECL.Contains($tag) -and $v.Length -gt 0) { $MNL.Add($nr); $MNT.Add($tag); $MNV.Add($v); $named = $true }
        $s = $r.Substring($e + 1)
      }
      if ($named) { $MTXT[$nr] = $line }
    }
  }

  # ---- inventory: code files ------------------------------------------------------------------
  $fileRr = New-SaSDict; $fileRin = New-SaSDict
  $rels = New-SaList
  # One directory at a time (like find, which reports an unreadable directory and goes on): an
  # unreadable directory loses only its own subtree. Reparse points (symlinks, junctions) are
  # skipped like find -P -type f does: no symlinked files, no descent into linked directories.
  $unreadable = $false
  $reparseAttr = [IO.FileAttributes]::ReparsePoint
  foreach ($r in $coderoots) {
    $rootLong = $dLong; $rootBase = $dBase
    if ($r.Length -gt 0) { $rootBase = $dBase + '\' + $r.Replace('/', '\'); $rootLong = $rootBase }
    if (-not [IO.Directory]::Exists($rootLong)) { continue }
    $cut = $rootBase.Length + 1
    $walkStack = New-Object 'System.Collections.Generic.Stack[string]'
    $walkStack.Push($rootLong)
    while ($walkStack.Count -gt 0) {
      $walkDir = $walkStack.Pop()
      $walkEnts = $null
      try { $walkEnts = (New-Object IO.DirectoryInfo($walkDir)).GetFileSystemInfos() } catch { $unreadable = $true; continue }
      foreach ($walkFe in $walkEnts) {
        if (($walkFe.Attributes -band $reparseAttr) -ne 0) { continue }
        $fp = $walkFe.FullName
        if (($walkFe.Attributes -band [IO.FileAttributes]::Directory) -ne 0) { $walkStack.Push($fp); continue }
        if (-not ($fp.EndsWith('.java', [StringComparison]::Ordinal) -or $fp.EndsWith('.kt', [StringComparison]::Ordinal) -or $fp.EndsWith('.smali', [StringComparison]::Ordinal))) { continue }
        $rin = $fp.Substring($cut).Replace('\', '/')
        $rel = $rin
        if ($r.Length -gt 0) { $rel = $r + '/' + $rin }
        if ($fileRr.ContainsKey($rel)) { continue }
        $rels.Add($rel); $fileRr[$rel] = $r; $fileRin[$rel] = $rin
      }
    }
  }
  $files = Get-SaSortedOrdinal $rels
  $longOf = { param([string]$Rel) return $dBase + '\' + $Rel.Replace('/', '\') }

  # domains and id prefixes of the tool group (dom.awk), one pass over all code
  $DomList = New-SaOList; $IdpList = New-SaOList
  foreach ($x in $domainsL) { if ($entById[$x[0]].Ing) { $DomList.Add(@($x[0], $x[1])) } }
  foreach ($x in $idpfxL) { if ($entById[$x[0]].Ing) { $IdpList.Add(@($x[0], $x[1])) } }
  $dp = New-SaList
  foreach ($x in $DomList) { $dp.Add($x[1]) }
  foreach ($x in $IdpList) { $dp.Add($x[1]) }
  $ReDom = New-SaLiteralRegex $dp
  $domHits = New-SaDict
  $CIdent = New-SaClassTable 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_$'
  $CIdentDot = New-SaClassTable 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_$.'
  $CHost = New-SaClassTable 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-'
  $CAlnum = New-SaClassTable 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'

  # ---- jadx package aliases (DESIGN 5.4 step 2) -------------------------------------------------
  $RN = New-SaSet
  $AlQ = New-SaSDict
  $aliases = New-SaOList           # @(P, Q, V) sorted
  $needle = '/* JADX INFO: renamed from: '
  if ($JADX) {
    $votes = New-SaIDict
    $jl = New-SaList
    foreach ($rel in $files) { if ($rel.EndsWith('.java', [StringComparison]::Ordinal)) { $jl.Add($rel) } }
    $jp = New-Object 'string[]' $jl.Count; $jf = New-Object 'int[]' $jl.Count
    for ($i = 0; $i -lt $jl.Count; $i++) { $jp[$i] = & $longOf $jl[$i]; $jf[$i] = 6 }
    $jt = Read-SaTexts $jp $jf $ReDom $needle
    for ($ji = 0; $ji -lt $jl.Count; $ji++) {
      $rel = $jl[$ji]
      $t = $jt[$ji]
      # unreadable, or neither a domain nor the renamed-from comment: no domain hit
      if ($null -eq $t) { $domHits[$rel] = $null; continue }
      if ($t.Length -eq 1 -and $t[0] -eq [char]0) { $domHits[$rel] = $null; continue }
      $domHits[$rel] = Get-SaDomHits $t
      $from = 0
      while (($p = $t.IndexOf($needle, $from, [StringComparison]::Ordinal)) -ge 0) {
        $from = $p + 1
        if ($p -gt 0 -and $t[$p - 1] -ne [char]"`n") { continue }
        $eol = $t.IndexOf([char]"`n", $p)
        if ($eol -lt 0) { $line = $t.Substring($p) } else { $line = $t.Substring($p, $eol - $p) }
        $nm = $line.Substring($needle.Length)
        $c = $nm.IndexOfAny([char[]]@([char]' ', [char]',', [char]'*'))
        if ($c -ge 0) { $nm = $nm.Substring(0, $c) }
        [void]$RN.Add($rel)
        $rin = $fileRin[$rel]
        $ls = $rin.LastIndexOf([char]'/')
        $dir = ''; if ($ls -ge 0) { $dir = $rin.Substring(0, $ls).Replace('/', '.') }
        $q = ''; $qd = $nm.LastIndexOf([char]'.'); if ($qd -ge 0) { $q = $nm.Substring(0, $qd) }
        if ($dir.Length -gt 0 -and $q.Length -gt 0 -and $q -cne $dir) {
          $vk = $dir + "`t" + $q
          if ($votes.ContainsKey($vk)) { $votes[$vk] = $votes[$vk] + 1 } else { $votes[$vk] = 1 }
        }
      }
    }
    $nv = New-SaIDict; $vq = New-SaSDict; $vv = New-SaIDict
    foreach ($vk in (Get-SaSortedOrdinal $votes.Keys)) {
      $tb = $vk.IndexOf([char]"`t"); $p = $vk.Substring(0, $tb); $q = $vk.Substring($tb + 1)
      if ($nv.ContainsKey($p)) { $nv[$p] = $nv[$p] + 1 } else { $nv[$p] = 1 }
      $vq[$p] = $q; $vv[$p] = $votes[$vk]
    }
    $cand = New-SaList
    foreach ($p in $nv.Keys) { if ($nv[$p] -eq 1) { $cand.Add($p + "`t" + $vq[$p] + "`t" + $vv[$p]) } }
    $acc0 = New-SaOList
    $dirJava = $null
    foreach ($cl in (Get-SaSortedOrdinal $cand)) {
      $a = $cl.Split([char]"`t")
      $p = $a[0]; $q = $a[1]; $v = [int]$a[2]
      $ok = $false
      if ($v -ge 2) { $ok = $true }
      else {
        $pd = $p.Replace('.', '/'); $qn = '"L' + $q.Replace('.', '/') + '/'
        if ($null -eq $dirJava) {
          # the .java files directly in each directory (find -maxdepth 1 -name '*.java')
          $dirJava = New-SaDict
          foreach ($rel in $files) {
            if (-not $rel.EndsWith('.java', [StringComparison]::Ordinal)) { continue }
            $ls = $rel.LastIndexOf([char]'/'); $dk = ''; if ($ls -ge 0) { $dk = $rel.Substring(0, $ls) }
            if (-not $dirJava.ContainsKey($dk)) { $dirJava[$dk] = New-SaList }
            $dirJava[$dk].Add($rel)
          }
        }
        foreach ($r in $coderoots) {
          $dk = $pd; if ($r.Length -gt 0) { $dk = $r + '/' + $pd }
          $dl0 = $null
          if (-not $dirJava.TryGetValue($dk, [ref]$dl0)) { continue }
          foreach ($rel in $dl0) {
            $t = Read-SaText (& $longOf $rel)
            if ($null -ne $t -and $t.IndexOf($qn, [StringComparison]::Ordinal) -ge 0) { $ok = $true; break }
          }
          if ($ok) { break }
        }
      }
      if ($ok) { $acc0.Add(@($p, $q, [string]$v)) }
    }
    # a sub-package alias P.x -> Q.x (same last segment) implies P -> Q when P has no vote for
    # another package; to a fixpoint
    $acc = New-SaSDict
    foreach ($x in $acc0) { $acc[$x[0]] = $x[1] }
    $ch = $true
    while ($ch) {
      $ch = $false
      for ($i = 0; $i -lt $acc0.Count; $i++) {
        $aP = $acc0[$i][0]; $aQ = $acc0[$i][1]
        $pp = Get-SaParent $aP; $qq = Get-SaParent $aQ
        if ($pp.Length -eq 0 -or $qq.Length -eq 0 -or $pp -ceq $qq -or (Get-SaLastSeg $aP) -cne (Get-SaLastSeg $aQ) -or $acc.ContainsKey($pp)) { continue }
        if ($nv.ContainsKey($pp) -and ($nv[$pp] -gt 1 -or $vq[$pp] -cne $qq)) { continue }
        $acc0.Add(@($pp, $qq, '0')); $acc[$pp] = $qq; $ch = $true
      }
    }
    $al = New-SaList
    foreach ($x in $acc0) { $al.Add($x[0] + "`t" + $x[1] + "`t" + $x[2]) }
    $n = 0
    foreach ($l in (Get-SaSortedOrdinal $al)) {
      $a = $l.Split([char]"`t")
      $aliases.Add($a)
      $AlQ[$a[0]] = $a[1]
      $n++
      if ($n -le 20) {
        $vt = $a[2] + ' votes'; if ($a[2] -ceq '0') { $vt = 'implied by a sub-package alias' }
        Write-SaErr ('[INFO] jadx package alias: ' + $a[0].Replace('.', '/') + ' -> ' + $a[1] + ' (' + $vt + ')')
      }
    }
    if ($n -gt 20) { Write-SaErr ('[INFO] ... and ' + ($n - 20) + ' more jadx package aliases (see --json input.aliases)') }
  }

  if ($unreadable) { Write-SaErr '[INFO] # unreadable directories skipped (check the permissions)' }
  Write-SaErr ('[INFO] code files: ' + $files.Length)

  # ---- ownership (lib.awk / inv.awk) ---------------------------------------------------------
  $RtRecs = New-SaDict
  $ADR = New-SaDict
  foreach ($x in $rootsL) {
    $l = $null
    if (-not $RtRecs.TryGetValue($x[0], [ref]$l)) { $l = New-SaOList; $RtRecs[$x[0]] = $l }
    $l.Add(@($x[1], $x[2]))
    if ($x[1] -ceq 'ad') {
      if (-not $ADR.ContainsKey($x[0])) { $ADR[$x[0]] = New-SaList }
      $ADR[$x[0]].Add($x[2])
    }
  }
  $OwnCache = New-SaDict; $OsCache = New-SaDict; $RwCache = New-SaSDict; $OsSelfCache = New-SaSDict
  $AcMap = New-SaIDict
  $MKByClass = New-SaDict
  foreach ($x in $markersL) { if (-not $MKByClass.ContainsKey($x[1])) { $MKByClass[$x[1]] = New-SaList }; $MKByClass[$x[1]].Add($x[0]) }
  $FKd = New-SaSDict; $FOwn = New-SaSDict; $FSelf = New-SaSDict; $FNp = New-SaSDict; $FNcls = New-SaSDict
  $FILECNT = New-SaIDict; $IDF = New-SaIDict
  $RC = New-SaOList; $rcIdx = New-SaIDict      # @(sdk, type, root, count, dir)
  $AD = New-SaOList; $adIdx = New-SaIDict      # @(mediator, network, count, dir)
  $MKF = New-SaSDict                           # sdk SUB class -> first file
  $MKFL = New-SaOList
  $rankOf = @{ 'id' = 1; 'inh' = 2; 'ns' = 3 }
  $pkgCache = New-SaDict
  foreach ($rel in $files) {
    $rr = $fileRr[$rel]; $rin = $fileRin[$rel]
    $seg = $rin.Split([char]'/')
    $bn = $seg[$seg.Length - 1]
    $ld = $bn.LastIndexOf([char]'.')
    $ext = $bn; $base = $bn
    if ($ld -ge 0) { $ext = $bn.Substring($ld + 1); $base = $bn.Substring(0, $ld) }
    $dir = ''
    if ($seg.Length -gt 1) { $dir = [string]::Join('.', $seg, 0, $seg.Length - 1) }
    $np = $dir
    if ($JADX) { $np = Get-SaAliasNorm $dir }
    if ($np.Length -eq 0) { $ncls = $base } else { $ncls = $np + '.' + $base }
    if ($np -cne $dir) {
      $ack = $base; if ($dir.Length -gt 0) { $ack = $dir + '.' + $base }
      if ($RN.Contains($rel)) { $AcMap[$ack] = 1 } else { $AcMap[$ack] = 0 }
    }
    # per package: kind, owners, self, records (best type per SDK: id > inh > ns > ad)
    $pi = $null
    if (-not $pkgCache.TryGetValue($np, [ref]$pi)) {
      $kd = 'app'; $owners = ''; $self = '-'; $bl = New-SaOList; $root = ''
      if ($APPPKG.Length -gt 0 -and ($np -ceq $APPPKG -or $np.StartsWith($APPPKG + '.', [StringComparison]::Ordinal))) { $kd = 'app' }
      else {
        $o = Get-SaOwner $np
        if ($null -ne $o) {
          $root = $o[0]
          $best = New-SaSDict; $order = New-SaList
          for ($j = 0; $j -lt $o[1].Length; $j++) {
            $t = $o[1][$j]; $s = $o[2][$j]
            if ($t -ceq 'lib') { continue }
            if (-not $best.ContainsKey($s)) { $order.Add($s); $best[$s] = $t }
            else {
              $r1 = 4; if ($rankOf.ContainsKey($t)) { $r1 = $rankOf[$t] }
              $r2 = 4; if ($rankOf.ContainsKey($best[$s])) { $r2 = $rankOf[$best[$s]] }
              if ($r1 -lt $r2) { $best[$s] = $t }
            }
          }
          if ($order.Count -eq 0) { $kd = 'lib' }
          else {
            $kd = 'sdk'
            foreach ($s in $order) {
              $t = $best[$s]
              if ($t -ceq 'inh') { $kd = 'inh'; $self = $s }
              $bl.Add(@($s, $t))
            }
            $owners = [string]::Join(' ', $order.ToArray())
          }
        }
      }
      # mediation adapters: <adapter root>.<network>...
      $adm = $null
      $p = $np; $child = ''
      while ($p.Length -gt 0) {
        if ($child.Length -gt 0 -and $ADR.ContainsKey($p)) { $adm = @($p, $child, $child.Substring($p.Length + 1)); break }
        $child = $p; $p = Get-SaParent $p
      }
      $pi = @{ Kd = $kd; Own = $owners; Self = $self; Bl = $bl; Root = $root; Ad = $adm }
      $pkgCache[$np] = $pi
    }
    $FKd[$rel] = $pi.Kd; $FSelf[$rel] = $pi.Self; $FNp[$rel] = $np; $FNcls[$rel] = $ncls
    if ($pi.Own.Length -eq 0) { $FOwn[$rel] = '-' } else { $FOwn[$rel] = $pi.Own }
    foreach ($b in $pi.Bl) {
      $s = $b[0]; $t = $b[1]
      if ($FILECNT.ContainsKey($s)) { $FILECNT[$s] = $FILECNT[$s] + 1 } else { $FILECNT[$s] = 1 }
      if ($t -ceq 'id' -or $t -ceq 'inh') { if ($IDF.ContainsKey($s)) { $IDF[$s] = $IDF[$s] + 1 } else { $IDF[$s] = 1 } }
      $k = $s + $SUB + $t + $SUB + $pi.Root
      $ix = 0
      if ($rcIdx.TryGetValue($k, [ref]$ix)) { $RC[$ix][3] = $RC[$ix][3] + 1 }
      else { $rcIdx[$k] = $RC.Count; $RC.Add(@($s, $t, $pi.Root, 1, (Get-SaRootDir $rel $np $pi.Root))) }
    }
    $ml = $null
    if ($MKByClass.TryGetValue($ncls, [ref]$ml)) {
      foreach ($s in $ml) {
        $k = $s + $SUB + $ncls
        if (-not $MKF.ContainsKey($k)) { $MKF[$k] = $rel }
      }
    }
    if ($null -ne $pi.Ad) {
      foreach ($s in $ADR[$pi.Ad[0]]) {
        $k = $s + $SUB + $pi.Ad[2]
        $ix = 0
        if ($adIdx.TryGetValue($k, [ref]$ix)) { $AD[$ix][2] = $AD[$ix][2] + 1 }
        else { $adIdx[$k] = $AD.Count; $AD.Add(@($s, $pi.Ad[2], 1, (Get-SaRootDir $rel $np $pi.Ad[1]))) }
      }
    }
  }

  # ---- app code: references, calls, hints (DESIGN 5.4 steps 3-4) ------------------------------
  $applist = New-SaList; $appJava = New-SaList
  foreach ($rel in $files) {
    $kd = $FKd[$rel]
    if ($kd -ceq 'app' -or $kd -ceq 'inh') {
      $applist.Add($rel)
      if ($rel.EndsWith('.java', [StringComparison]::Ordinal) -or $rel.EndsWith('.kt', [StringComparison]::Ordinal)) { $appJava.Add($rel) }
    }
  }
  Write-SaErr ('[INFO] app code files: ' + $applist.Count)
  # one read of every code file: domains (unless done in the alias pass) + app code texts
  $appText = New-SaSDict
  $appSet = New-SaSet
  foreach ($rel in $applist) { [void]$appSet.Add($rel) }
  $rl = New-SaList; $fl = New-Object 'System.Collections.Generic.List[int]'
  foreach ($rel in $files) {
    $f = 0
    if ($appSet.Contains($rel)) { $f = 1 }
    if (-not $domHits.ContainsKey($rel)) { $f = $f -bor 2 }
    if ($f -ne 0) { $rl.Add($rel); $fl.Add($f) }
  }
  $rp = New-Object 'string[]' $rl.Count
  for ($i = 0; $i -lt $rl.Count; $i++) { $rp[$i] = & $longOf $rl[$i] }
  $rt = Read-SaTexts $rp $fl.ToArray() $ReDom ''
  for ($ri = 0; $ri -lt $rl.Count; $ri++) {
    $rel = $rl[$ri]; $f = $fl[$ri]; $t = $rt[$ri]
    if ($null -eq $t -or ($t.Length -eq 1 -and $t[0] -eq [char]0)) { if ($f -band 2) { $domHits[$rel] = $null }; continue }
    if ($f -band 2) { $domHits[$rel] = Get-SaDomHits $t }
    if ($f -band 1) { $appText[$rel] = $t }
  }

  # prefilter patterns: roots (dotted + smali), alias packages, simple names of API and marker
  # classes, ".method(" of every API method, app_code hint tokens
  $patsRoots = New-SaList
  foreach ($x in $rootsL) { if ($x[1] -cne 'lib' -and $x[1] -cne 'ex') { $patsRoots.Add($x[0]); $patsRoots.Add('L' + $x[0].Replace('.', '/') + '/') } }
  foreach ($a in $aliases) { $patsRoots.Add($a[0]) }
  $pats = New-SaList
  $pats.AddRange($patsRoots)
  foreach ($x in $apiL) {
    $c = Get-SaLastSeg $x[0]; $dl = $c.IndexOf([char]'$'); if ($dl -ge 0) { $c = $c.Substring(0, $dl) }
    $pats.Add($c)
    if ($x[1] -cne '<init>') { $pats.Add('.' + $x[1] + '(') }
  }
  foreach ($x in $markersL) { $pats.Add((Get-SaLastSeg $x[1])) }
  foreach ($x in $htokL) { if ($x[3] -ceq 'app_code') { $pats.Add($x[1]) } }

  # pass 1 over the app Java/Kotlin code: simple names of the imported SDK classes and the SDK
  # packages imported with a wildcard (imp.awk)
  $ReImportLine = New-Object System.Text.RegularExpressions.Regex('^[ \t]*import[ \t]', 'CultureInvariant')
  $RePackageLine = New-Object System.Text.RegularExpressions.Regex('^[ \t]*package[ \t]', 'CultureInvariant')
  $ReImpHead = New-Object System.Text.RegularExpressions.Regex('^[ \t]*import[ \t]+', 'CultureInvariant')
  $ReStatic = New-Object System.Text.RegularExpressions.Regex('^static[ \t]+', 'CultureInvariant')
  $ReSemi = New-Object System.Text.RegularExpressions.Regex('[ \t]*;.*$', 'CultureInvariant')
  $ReAs = New-Object System.Text.RegularExpressions.Regex('[ \t]+as[ \t]+', 'CultureInvariant')
  $reRoots = New-SaLiteralRegex $patsRoots
  $impS = New-SaSet; $WILD = New-SaSet
  if ($null -ne $reRoots) {
    foreach ($rel in $appJava) {
      $t = $null
      if (-not $appText.TryGetValue($rel, [ref]$t)) { continue }
      if (-not $reRoots.IsMatch($t)) { continue }
      foreach ($line in (Get-SaLines $t)) {
        if (-not $reRoots.IsMatch($line)) { continue }
        $s = Remove-SaCr $line
        if (-not $ReImportLine.IsMatch($s)) { continue }
        $x = Split-SaImport $s
        $s = $x[0]; $asn = $x[1]
        if ($s.EndsWith('.*', [StringComparison]::Ordinal)) {
          $p = Get-SaRewrite $s.Substring(0, $s.Length - 2)
          if ((Get-SaOwnerSdks $p '').Length -gt 0) { [void]$WILD.Add($p) }
          continue
        }
        $s = Get-SaRewrite $s
        if ((Get-SaOwnerSdks $s '').Length -eq 0) { continue }
        [void]$impS.Add((Get-SaLastSeg $s))
        if ($asn.Length -gt 0) { [void]$impS.Add($asn) }
      }
    }
  }
  $pats.AddRange($impS)
  $WildCls = New-SaSet
  if ($WILD.Count -gt 0) {
    foreach ($rel in $files) {
      $nc = $FNcls[$rel]
      if ($WILD.Contains((Get-SaStripLastSeg $nc))) { $pats.Add((Get-SaLastSeg $nc)); [void]$WildCls.Add($nc) }
    }
  }
  $rePats = New-SaLiteralRegex $pats

  # app.awk
  $ReTok = New-Object System.Text.RegularExpressions.Regex('[A-Za-z_$][A-Za-z0-9_$]*(?:\.[A-Za-z_$][A-Za-z0-9_$]*)+', 'CultureInvariant')
  $ReWord = New-Object System.Text.RegularExpressions.Regex('[A-Za-z_$][A-Za-z0-9_$]*', 'CultureInvariant')
  $ReCall = New-Object System.Text.RegularExpressions.Regex('\.[A-Za-z_$][A-Za-z0-9_$]*\(', 'CultureInvariant')
  $ReNew = New-Object System.Text.RegularExpressions.Regex('new[ \t]+[A-Za-z_$][A-Za-z0-9_$.]*[ \t]*[(<]', 'CultureInvariant')
  $ReKt = New-Object System.Text.RegularExpressions.Regex('[A-Za-z_$][A-Za-z0-9_$.]*\(', 'CultureInvariant')
  $ReSmali = New-Object System.Text.RegularExpressions.Regex('L[A-Za-z0-9_$/]+;', 'CultureInvariant')
  $ReSmaliComment = New-Object System.Text.RegularExpressions.Regex('^[ \t]*#', 'CultureInvariant')
  $ReJavaComment = New-Object System.Text.RegularExpressions.Regex('^[ \t]*(?://|/\*|\*)', 'CultureInvariant')
  $APIC = New-SaSet; $APIM = New-SaSet; $APIR = New-SaSDict; $OUTERS = New-SaDict; $APIPKG = New-SaDict
  foreach ($x in $apiL) {
    $k = $x[0]
    $o = Get-SaOwner $k
    if ($null -ne $o -and -not ($o[2] -ccontains $x[3])) { continue }
    [void]$APIC.Add($k); [void]$APIM.Add($x[1])
    $rk = $k + $SUB + $x[1]
    if ($APIR.ContainsKey($rk)) { $APIR[$rk] = $APIR[$rk] + ' ' + $x[2] + ':' + $x[3] } else { $APIR[$rk] = ' ' + $x[2] + ':' + $x[3] }
    $ok = $k; $dl = $ok.IndexOf([char]'$'); if ($dl -ge 0) { $ok = $ok.Substring(0, $dl) }
    if (-not $OUTERS.ContainsKey($ok)) { $OUTERS[$ok] = New-SaList }
    if (-not $OUTERS[$ok].Contains($k)) { $OUTERS[$ok].Add($k) }
    $pk0 = Get-SaStripLastSeg $k
    if (-not $APIPKG.ContainsKey($pk0)) { $APIPKG[$pk0] = New-SaList }
    if (-not $APIPKG[$pk0].Contains($k)) { $APIPKG[$pk0].Add($k) }
  }
  $AppHints = New-SaOList
  foreach ($x in $htokL) { if ($x[3] -ceq 'app_code') { $AppHints.Add(@($x[0], $x[1], $x[2])) } }
  $Ev = @{
    RR = New-SaList; RL = New-SaList; RSD = New-SaList; RK = New-SaList; RIDX = New-SaIDict
    CRl = New-SaList; CLn = New-SaList; CS = New-SaList; CRo = New-SaList; CA = New-SaList; CF = New-SaList; CSEEN = New-SaIDict
    HER = New-SaList; HEL = New-SaList; HEI = New-SaList
  }
  $TXT = New-SaSDict
  $LS = @{ cur = ''; ln = ''; self = ''; evn = 0 }
  $VIS = New-SaSDict; $VSD = New-SaSDict; $VLIST = New-SaList; $FW = New-SaList; $FWSET = New-SaSet
  if ($null -ne $rePats) {
    foreach ($rel in $applist) {
      $t = $null
      if (-not $appText.TryGetValue($rel, [ref]$t)) { continue }
      if (-not $rePats.IsMatch($t)) { continue }
      $ext = $rel.Substring($rel.LastIndexOf([char]'.') + 1)
      $isSmali = ($ext -ceq 'smali')
      $first = $true
      $lines = Get-SaLines $t
      for ($li = 0; $li -lt $lines.Length; $li++) {
        if (-not $rePats.IsMatch($lines[$li])) { continue }
        $s = Remove-SaCr $lines[$li]
        if ($first) {
          # newfile
          $first = $false
          $LS.cur = $rel
          $sf = $FSelf[$rel]; if ($sf -ceq '-') { $sf = '' }
          $LS.self = $sf
          $VIS.Clear(); $VSD.Clear(); $VLIST.Clear(); $FW.Clear(); $FWSET.Clear()
          $pl = $null
          if ($APIPKG.TryGetValue($FNp[$rel], [ref]$pl)) {
            foreach ($k in $pl) {
              $jk = $k.Replace('$', '.')
              Add-SaVis (Get-SaLastSeg $k) $jk (Get-SaOwnerSdks $jk $LS.self)
            }
          }
        }
        $LS.ln = [string]($li + 1)
        $LS.evn = 0
        # comment-only lines (jadx "/* JADX INFO: ... */", "// ...", smali "# ...") are no evidence
        if ($isSmali) { if ($ReSmaliComment.IsMatch($s)) { continue } } elseif ($ReJavaComment.IsMatch($s)) { continue }
        if ($isSmali) { Invoke-SaSmaliLine $s } else { Invoke-SaJavaLine $s $ext }
        Invoke-SaHints $s
        if ($LS.evn -gt 0) { $TXT[$rel + $SUB + $LS.ln] = $s }
      }
    }
  }

  # ---- domains and id prefixes over all code (dom.awk) ---------------------------------------
  $DK = New-SaList; $DR = New-SaList; $DL = New-SaList; $DS = New-SaList; $DV = New-SaList; $DE = New-SaList
  $dseen = New-SaSet
  foreach ($rel in $files) {
    $h = $null
    if (-not $domHits.TryGetValue($rel, [ref]$h) -or $null -eq $h) { continue }
    $fk = $FKd[$rel]; $fo = ' ' + $FOwn[$rel] + ' '
    $curLn = ''; $any = $false; $curText = ''
    foreach ($rec in $h) {
      if ($rec[0] -cne $curLn) {
        if ($any) { $TXT[$rel + $SUB + $curLn] = $curText }
        $curLn = $rec[0]; $any = $false; $curText = $rec[4]
      }
      $el = '0'
      if ($fk -ceq 'app' -or $fk -ceq 'inh' -or $fo.IndexOf(' ' + $rec[2] + ' ', [StringComparison]::Ordinal) -ge 0) { $el = '1'; $any = $true }
      $k = $rec[1] + $SUB + $rel + $SUB + $rec[0] + $SUB + $rec[2] + $SUB + $rec[3]
      if ($dseen.Add($k)) { $DK.Add($rec[1]); $DR.Add($rel); $DL.Add($rec[0]); $DS.Add($rec[2]); $DV.Add($rec[3]); $DE.Add($el) }
    }
    if ($any) { $TXT[$rel + $SUB + $curLn] = $curText }
  }

  # ---- verdict (rep.awk analyse) ------------------------------------------------------------------
  $RR = $Ev.RR; $RL = $Ev.RL; $RSD = $Ev.RSD; $RK = $Ev.RK
  $CRl = $Ev.CRl; $CLn = $Ev.CLn; $CS = $Ev.CS; $CRo = $Ev.CRo; $CA = $Ev.CA; $CF = $Ev.CF
  $HER = $Ev.HER; $HEL = $Ev.HEL; $HEI = $Ev.HEI
  $nr = $RR.Count; $nc = $CRl.Count; $nd = $DK.Count; $nmn = $MNL.Count; $nhe = $HER.Count
  $APPREF = New-SaIDict; $CALLN = New-SaIDict; $ENDP = New-SaIDict; $LIBDOM = New-SaIDict; $IDP = New-SaIDict; $MANIF = New-SaIDict
  $inc = { param($D, [string]$K) if ($D.ContainsKey($K)) { $D[$K] = $D[$K] + 1 } else { $D[$K] = 1 } }
  $n0 = { param($D, [string]$K) if ($D.ContainsKey($K)) { return $D[$K] }; return 0 }
  for ($i = 0; $i -lt $nr; $i++) { & $inc $APPREF $RSD[$i] }
  for ($i = 0; $i -lt $nc; $i++) { & $inc $CALLN $CS[$i] }
  for ($i = 0; $i -lt $nd; $i++) {
    if ($DK[$i] -ceq 'E') { if ($DE[$i] -ceq '1') { & $inc $ENDP $DS[$i] } else { & $inc $LIBDOM $DS[$i] } }
    elseif ($DE[$i] -ceq '1') { & $inc $IDP $DS[$i] }
  }
  $MN = New-SaDict; foreach ($x in $mnamesL) { if (-not $MN.ContainsKey($x[1])) { $MN[$x[1]] = New-SaList }; $MN[$x[1]].Add($x[0]) }
  $MC = New-SaDict; foreach ($x in $mcompsL) { if (-not $MC.ContainsKey($x[1])) { $MC[$x[1]] = New-SaList }; $MC[$x[1]].Add($x[0]) }
  $MSD = New-SaList
  for ($i = 0; $i -lt $nmn; $i++) {
    $nm = $MNV[$i]
    $sd = New-SaList
    $o = Get-SaOwner $nm
    if ($null -ne $o) { for ($j = 0; $j -lt $o[1].Length; $j++) { if (($o[1][$j] -ceq 'id' -or $o[1][$j] -ceq 'inh') -and -not $sd.Contains($o[2][$j])) { $sd.Add($o[2][$j]) } } }
    $l = $null
    if ($MN.TryGetValue($nm, [ref]$l)) { foreach ($s in $l) { if (-not $sd.Contains($s)) { $sd.Add($s) } } }
    if ($MC.TryGetValue($nm, [ref]$l) -and $null -ne $o) {
      foreach ($s in $l) {
        for ($k = 0; $k -lt $o[1].Length; $k++) {
          if ($o[2][$k] -ceq $s -and ($o[1][$k] -ceq 'id' -or $o[1][$k] -ceq 'inh' -or $o[1][$k] -ceq 'ns') -and -not $sd.Contains($s)) { $sd.Add($s) }
        }
      }
    }
    $str = ' '
    foreach ($s in $sd) { $str += $s + ' ' }
    $MSD.Add($str)
    foreach ($s in $sd) { & $inc $MANIF $s }
  }
  $NMK = New-SaDict
  foreach ($x in $markersL) { if (-not $NMK.ContainsKey($x[0])) { $NMK[$x[0]] = New-SaList }; $NMK[$x[0]].Add($x[1]) }
  $mkOf = { param([string]$S) $l = $null; if ($NMK.TryGetValue($S, [ref]$l)) { return ,$l.ToArray() }; return ,([string[]]@()) }
  $LV = New-SaSDict; $DET = New-SaSDict; $ST = New-SaSDict; $LVN = New-SaIDict; $ACT = New-SaSDict
  foreach ($e in $ents) {
    $s = $e.Id
    $mks = & $mkOf $s
    $nf = 0
    foreach ($mk in $mks) { if ($MKF.ContainsKey($s + $SUB + $mk)) { $nf++ } }
    if ((& $n0 $IDF $s) -gt 0) {
      if ($mks.Length -eq 0 -or $nf -gt 0) { $LV[$s] = 'HIGH'; $DET[$s] = '-' } else { $LV[$s] = 'MEDIUM'; $DET[$s] = 'partial' }
    } elseif ((& $n0 $MANIF $s) -gt 0) { $LV[$s] = 'MEDIUM'; $DET[$s] = 'manifest-only' }
    elseif ((& $n0 $APPREF $s) -gt 0 -or (& $n0 $ENDP $s) -gt 0 -or (& $n0 $IDP $s) -gt 0) {
      $LV[$s] = 'LOW'; $dt = New-SaList
      if ((& $n0 $APPREF $s) -gt 0) { $dt.Add('app-refs') }
      if ((& $n0 $ENDP $s) -gt 0) { $dt.Add('endpoints') }
      if ((& $n0 $IDP $s) -gt 0) { $dt.Add('id-prefix') }
      $DET[$s] = [string]::Join('+', $dt.ToArray())
    } else { $LV[$s] = 'NONE'; $DET[$s] = '-' }
    switch -CaseSensitive ($LV[$s]) {
      'HIGH' { $ST[$s] = 'DETECTED'; $LVN[$s] = 3 }
      'MEDIUM' { $ST[$s] = 'LIKELY'; $LVN[$s] = 2 }
      'LOW' { $ST[$s] = 'POSSIBLE'; $LVN[$s] = 1 }
      default { $ST[$s] = 'NOT FOUND'; $LVN[$s] = 0 }
    }
    if ((& $n0 $APPREF $s) + (& $n0 $CALLN $s) -gt 0) { $ACT[$s] = 'true' } else { $ACT[$s] = 'false' }
  }
  $ING = { param([string]$S) $e = $null; if ($entById.TryGetValue($S, [ref]$e)) { return [bool]$e.Ing }; return $false }
  $GRPOF = { param([string]$S) $e = $null; if ($entById.TryGetValue($S, [ref]$e)) { return [string]$e.Grp }; return '' }
  $lab = { param($E) if ($E.Flag -cne '-') { return $E.Label }; return $E.Disp }
  $txtOf = { param([string]$Rel, [string]$Ln) $v = $null; if ($TXT.TryGetValue($Rel + $SUB + $Ln, [ref]$v)) { return $v }; return '' }

  # hints (hint_counts / mhints)
  $HCL = New-SaIDict; $HCF = New-SaIDict
  $mhCache = New-SaDict
  $mhints = {
    param([int]$I)
    $c = $null
    if ($mhCache.TryGetValue([string]$I, [ref]$c)) { return [string]$c }
    $out = ''
    foreach ($h in $htokL) {
      if ($h[3] -cne 'manifest') { continue }
      $id = $h[0]; $t = $h[1]
      if ((' ' + $out + ' ').IndexOf(' ' + $id + ' ', [StringComparison]::Ordinal) -ge 0) { continue }
      $ok = $false
      if ($h[2] -ceq 'exact') { $ok = ($MNV[$I] -ceq $t) }
      elseif ($h[2] -ceq 'literal') { $ok = ($MNV[$I].IndexOf($t, [StringComparison]::Ordinal) -ge 0 -and $MSD[$I] -ceq ' ') }
      if ($ok) { $out = $out + ' ' + $id }
    }
    $mhCache[[string]$I] = $out
    return $out
  }
  $hintsCounted = $false
  $hintCounts = {
    if ($hintsCounted) { return }
    $hsn = New-SaSet; $hsf = New-SaSet
    for ($i = 0; $i -lt $nhe; $i++) {
      $id = $HEI[$i]
      if (-not $hsn.Add($HER[$i] + $SUB + $HEL[$i] + $SUB + $id)) { continue }
      & $inc $HCL $id
      if ($hsf.Add($HER[$i] + $SUB + $id)) { & $inc $HCF $id }
    }
    $mhs = New-SaSet
    for ($i = 0; $i -lt $nmn; $i++) {
      foreach ($id in (Split-SaWs (& $mhints $i))) {
        if ($mhs.Add($MNL[$i] + $SUB + $id)) { & $inc $HCL $id; $HCF[$id] = 1 }
      }
    }
    Set-Variable -Name hintsCounted -Value $true -Scope 1
  }
  # entry points: every R and C line of the tool group (app code)
  $EPR = New-SaList; $EPL = New-SaList; $EPA = New-SaSDict; $epFiles = New-SaSet
  $epAdd = {
    param([string]$Rel, [string]$Ln, [string]$Ann)
    $k = $Rel + $SUB + $Ln
    if (-not $EPA.ContainsKey($k)) { $EPA[$k] = ''; $EPR.Add($Rel); $EPL.Add($Ln); [void]$epFiles.Add($Rel) }
    $cur = $EPA[$k]
    if ((' ' + $cur + ' ').IndexOf(' ' + $Ann + ' ', [StringComparison]::Ordinal) -lt 0) { if ($cur.Length -eq 0) { $EPA[$k] = $Ann } else { $EPA[$k] = $cur + ' ' + $Ann } }
  }
  $epDone = $false
  $epCollect = {
    if ($epDone) { return }
    for ($i = 0; $i -lt $nr; $i++) { if (& $ING $RSD[$i]) { & $epAdd $RR[$i] $RL[$i] ($RSD[$i] + '/ref') } }
    for ($i = 0; $i -lt $nc; $i++) {
      if (& $ING $CS[$i]) { $q = '?'; if ($CF[$i] -ceq 'exact') { $q = '' }; & $epAdd $CRl[$i] $CLn[$i] ($CS[$i] + '/' + $CRo[$i] + $q) }
    }
    Set-Variable -Name epDone -Value $true -Scope 1
  }

  $out = New-Object 'System.Collections.Generic.List[string]'
  # ---- --tsv ---------------------------------------------------------------------------------------
  if ($mode -ceq 'tsv') {
    $out.Add("#sdk-audit`t2`ttool=" + $Tool + "`tlayout=" + $LAYOUT)
    foreach ($a in $aliases) { $out.Add("#alias`t" + $a[0].Replace('.', '/') + "`t" + $a[1] + "`t" + $a[2]) }
    foreach ($e in $ents) {
      if (-not $e.Ing) { continue }
      $s = $e.Id
      $tg = 'false'; if ($e.Tgt) { $tg = 'true' }
      $out.Add("SDK`t" + $s + "`t" + $e.Cat + "`t" + $LV[$s] + "`t" + $ST[$s] + "`t" + $DET[$s] + "`t" + $tg + "`tfiles=" + (& $n0 $FILECNT $s) +
               "`tmanifest=" + (& $n0 $MANIF $s) + "`tendpoints=" + (& $n0 $ENDP $s) + "`tapp_refs=" + (& $n0 $APPREF $s) + "`tcalls=" + (& $n0 $CALLN $s) + "`tactive=" + $ACT[$s])
    }
    $TT = @('id', 'inh', 'ns', 'ad'); $KW = @('package', 'package', 'namespace', 'adapter')
    foreach ($e in $ents) {
      if (-not $e.Ing) { continue }
      $s = $e.Id
      for ($t = 0; $t -lt 4; $t++) { foreach ($x in $RC) { if ($x[0] -ceq $s -and $x[1] -ceq $TT[$t]) { $out.Add("EV`t" + $s + "`t" + $KW[$t] + "`t" + $x[2] + "`t" + $x[3]) } } }
      if ((& $n0 $IDF $s) -gt 0) { foreach ($mk in (& $mkOf $s)) { $f1 = '0'; if ($MKF.ContainsKey($s + $SUB + $mk)) { $f1 = '1' }; $out.Add("EV`t" + $s + "`tmarker`t" + $mk + "`t" + $f1) } }
      $evm = New-SaSet
      for ($j = 0; $j -lt $nmn; $j++) {
        if ($MSD[$j].IndexOf(' ' + $s + ' ', [StringComparison]::Ordinal) -ge 0 -and $evm.Add($MNT[$j] + $SUB + $MNV[$j])) { $out.Add("EV`t" + $s + "`tmanifest`t" + $MNT[$j] + "`t" + $MNV[$j]) }
      }
      $cnt = New-SaIDict; $ord = New-SaList
      for ($j = 0; $j -lt $nd; $j++) {
        if ($DS[$j] -ceq $s -and $DE[$j] -ceq '1') { $k = $DK[$j] + $SUB + $DV[$j]; if (-not $cnt.ContainsKey($k)) { $ord.Add($k); $cnt[$k] = 0 }; $cnt[$k] = $cnt[$k] + 1 }
      }
      foreach ($k in $ord) { $a = $k.Split([char]0x1c); $kn = 'id_prefix'; if ($a[0] -ceq 'E') { $kn = 'domain' }; $out.Add("EV`t" + $s + "`t" + $kn + "`t" + $a[1] + "`t" + $cnt[$k]) }
      if ((& $n0 $LIBDOM $s) -gt 0) { $out.Add("EV`t" + $s + "`tlib_domain_hits`t-`t" + $LIBDOM[$s]) }
    }
    $ck = New-SaList; $cv = New-SaSDict
    for ($i = 0; $i -lt $nc; $i++) {
      if (-not (& $ING $CS[$i])) { continue }
      $k = $CRl[$i] + "`0" + ([long]$CLn[$i]).ToString('D12') + "`0" + $CS[$i] + "`0" + $CRo[$i] + "`0" + $CA[$i]
      if ($cv.ContainsKey($k)) { continue }
      $ck.Add($k); $cv[$k] = "CALL`t" + $CS[$i] + "`t" + $CRo[$i] + "`t" + $CA[$i] + "`t" + $CRl[$i] + ':' + $CLn[$i] + "`t" + $CF[$i]
    }
    foreach ($k in (Get-SaSortedOrdinal $ck)) { $out.Add($cv[$k]) }
    if (-not $noHints) {
      & $hintCounts
      foreach ($h in $hintsL) { if ((& $n0 $HCL $h[0]) -gt 0) { $out.Add("HINT`t" + $h[0] + "`t" + $HCF[$h[0]] + "`t" + $HCL[$h[0]]) } }
    }
    if ($Tool -ceq 'find-ads') { foreach ($x in $AD) { $out.Add("ADAPTER`t" + $x[0] + "`t" + $x[1] + "`t" + $x[2]) } }
    $Holder.Out = [string]::Join("`n", $out.ToArray())
    return
  }

  # ---- --summary -----------------------------------------------------------------------------------
  if ($mode -ceq 'summary') {
    $out.Add('')
    if ($Tool -ceq 'find-trackers') { $out.Add('=== Tracker Detection Summary ===') } else { $out.Add('=== Ad SDK Detection Summary ===') }
    $out.Add('')
    $fmtRow = {
      param($A)
      return (Format-SaPad $A[0] 22 $true) + ' | ' + (Format-SaPad $A[1] 20 $true) + ' | ' + (Format-SaPad $A[2] 5 $false) + ' | ' +
             (Format-SaPad $A[3] 5 $false) + ' | ' + (Format-SaPad $A[4] 4 $false) + ' | ' + (Format-SaPad $A[5] 6 $false) + ' | ' +
             (Format-SaPad $A[6] 6 $true) + ' | ' + (Format-SaPad $A[7] 9 $true) + ' | ' + $A[8]
    }
    $out.Add((& $fmtRow @('SDK', 'SDK_ID', 'FILES', 'MANIF', 'ENDP', 'APPREF', 'CONF', 'STATUS', 'NEUTRALIZE')))
    foreach ($e in $ents) {
      if (-not $e.Ing) { continue }
      $s = $e.Id
      if ($e.Rank -ge 1000 -and $LVN[$s] -eq 0) { continue }
      $nz = 'no (detection-only)'; if ($e.Tgt) { $nz = 'yes' }
      $out.Add((& $fmtRow @((& $lab $e), $s, [string](& $n0 $FILECNT $s), [string](& $n0 $MANIF $s), [string](& $n0 $ENDP $s), [string](& $n0 $APPREF $s), $LV[$s], $ST[$s], $nz)))
    }
    & $epCollect
    $out.Add('')
    $out.Add('Entry points in app code: ' + $EPR.Count + ' call site(s) in ' + $epFiles.Count + ' file(s)')
    $mm = 0
    for ($i = 0; $i -lt $nmn; $i++) { foreach ($s in (Split-SaWs $MSD[$i])) { if (& $ING $s) { $mm++; break } } }
    $out.Add('Manifest markers: ' + $mm + ' match(es)')
    if ($Tool -ceq 'find-ads') {
      $out.Add('Mediation adapters: ' + $AD.Count)
      $cons = New-SaList
      foreach ($e in $ents) { if ($e.Ing -and $e.Grp -ceq 'consent' -and $LVN[$e.Id] -gt 0) { $cons.Add($e.Id + ' ' + $LV[$e.Id]) } }
      if ($cons.Count -eq 0) { $out.Add('Consent framework: none') } else { $out.Add('Consent framework: ' + [string]::Join(', ', $cons.ToArray())) }
    }
    $lst = New-SaList
    foreach ($e in $ents) { if ($e.Ing -and -not $e.Tgt -and $LVN[$e.Id] -ge 2) { $lst.Add($e.Id) } }
    if ($lst.Count -gt 0) { $out.Add('Detected but NOT neutralized by sdk-neutralizer (no registry targets): ' + [string]::Join(' ', $lst.ToArray())) }
    if (-not $noHints) {
      & $hintCounts
      $hs = ''
      foreach ($h in $hintsL) { if ((& $n0 $HCL $h[0]) -gt 0) { $hs += ' ' + $h[0] + '=' + $HCL[$h[0]] } }
      if ($hs.Length -eq 0) { $hs = ' none' }
      $out.Add('Hints (informational, never counted):' + $hs)
    }
    $out.Add('Confidence: HIGH = SDK code present (+ marker class when declared); MEDIUM = code without declared marker, or AndroidManifest only; LOW = app-code references / endpoints only; NONE = not detected')
    $Holder.Out = [string]::Join("`n", $out.ToArray())
    return
  }

  # ---- --json ------------------------------------------------------------------------------------
  if ($mode -ceq 'json') {
    $sdks = New-SaOList
    foreach ($e in $ents) {
      $s = $e.Id
      if (-not $e.Ing -or $LVN[$s] -eq 0) { continue }
      $pp = New-SaOList
      foreach ($x in $RC) { if ($x[0] -ceq $s -and ($x[1] -ceq 'id' -or $x[1] -ceq 'inh')) { $pp.Add($x[2]) } }
      $mf = New-SaOList; $mmiss = New-SaOList
      foreach ($mk in (& $mkOf $s)) { if ($MKF.ContainsKey($s + $SUB + $mk)) { $mf.Add($mk) } else { $mmiss.Add($mk) } }
      $manRecs = New-SaOList
      for ($j = 0; $j -lt $nmn; $j++) { if ($MSD[$j].IndexOf(' ' + $s + ' ', [StringComparison]::Ordinal) -ge 0) { $manRecs.Add([ordered]@{ tag = $MNT[$j]; name = $MNV[$j]; line = [int]$MNL[$j] }) } }
      $cnt = New-SaIDict; $ord = New-SaList
      for ($j = 0; $j -lt $nd; $j++) {
        if ($DS[$j] -ceq $s -and $DE[$j] -ceq '1' -and $DK[$j] -ceq 'E') { $k = $DV[$j]; if (-not $cnt.ContainsKey($k)) { $ord.Add($k); $cnt[$k] = 0 }; $cnt[$k] = $cnt[$k] + 1 }
      }
      $doms = New-SaOList
      foreach ($k in $ord) { $doms.Add([ordered]@{ domain = $k; hits = $cnt[$k] }) }
      $calls = New-SaOList
      for ($j = 0; $j -lt $nc; $j++) {
        if ($CS[$j] -ceq $s) { $calls.Add([ordered]@{ role = $CRo[$j]; api = $CA[$j]; path = (& $pathOf $CRl[$j]); line = [int]$CLn[$j]; confidence = $CF[$j] }) }
      }
      $lbl = $s; if ($e.Flag -cne '-') { $lbl = $e.Label }
      $sdks.Add([ordered]@{
        sdk = $lbl; sdk_id = $s; display_name = $e.Disp; category = $e.Cat; group = $e.Grp
        confidence = $LV[$s]; status = $ST[$s]; detail = $DET[$s]; neutralizable = [bool]$e.Tgt; active = ($ACT[$s] -ceq 'true')
        evidence = [ordered]@{
          files = [int](& $n0 $FILECNT $s); packages_present = [object[]]$pp.ToArray(); markers_found = [object[]]$mf.ToArray()
          markers_missing = [object[]]$mmiss.ToArray(); manifest = [object[]]$manRecs.ToArray(); domains = [object[]]$doms.ToArray()
          app_refs = [int](& $n0 $APPREF $s); calls = [object[]]$calls.ToArray(); lib_domain_hits = [int](& $n0 $LIBDOM $s)
        }
      })
    }
    $crs = New-SaOList
    foreach ($r in $coderoots) { $crs.Add((& $pathOf $r)) }
    $mfs = New-SaOList
    if ($MANDISP.Length -gt 0) { $mfs.Add($MANDISP) }
    $als = New-SaOList
    foreach ($a in $aliases) { $als.Add([ordered]@{ from = $a[0].Replace('.', '/'); to = $a[1]; votes = [int]$a[2] }) }
    $doc = [ordered]@{
      schema_version = 2; tool = $Tool
      input = [ordered]@{ path = $DISP; layout = $LAYOUT; code_roots = [object[]]$crs.ToArray(); manifests = [object[]]$mfs.ToArray(); aliases = [object[]]$als.ToArray() }
    }
    $strip = { param($O) $c = [ordered]@{}; foreach ($k in $O.Keys) { if ($k -cne 'group') { $c[$k] = $O[$k] } }; return $c }
    if ($Tool -ceq 'find-ads') {
      $adl = New-SaOList; $col = New-SaOList
      foreach ($x in $sdks) { if ($x.group -ceq 'ads') { $adl.Add((& $strip $x)) } elseif ($x.group -ceq 'consent') { $col.Add((& $strip $x)) } }
      $doc.ad_sdks = [object[]]$adl.ToArray(); $doc.consent_sdks = [object[]]$col.ToArray()
    } else {
      $tl = New-SaOList
      foreach ($x in $sdks) { $tl.Add((& $strip $x)) }
      $doc.trackers = [object[]]$tl.ToArray()
    }
    & $epCollect
    $eps = New-SaOList
    for ($i = 0; $i -lt $EPR.Count; $i++) {
      $k = $EPR[$i] + $SUB + $EPL[$i]
      $eps.Add([ordered]@{ path = (& $pathOf $EPR[$i]); line = [int]$EPL[$i]; sdks = [object[]]($EPA[$k].Split([char]' ')); text = (& $txtOf $EPR[$i] $EPL[$i]).Replace("`t", ' ') })
    }
    $doc.entry_points = [object[]]$eps.ToArray()
    $hn = [ordered]@{}
    if (-not $noHints) {
      & $hintCounts
      foreach ($h in $hintsL) { if ((& $n0 $HCL $h[0]) -gt 0) { $hn[$h[0]] = [ordered]@{ files = [int]$HCF[$h[0]]; lines = [int]$HCL[$h[0]] } } }
    }
    $doc.hints = $hn
    $nn = New-SaOList
    foreach ($e in $ents) { if ($e.Ing -and $LVN[$e.Id] -ne 0 -and -not $e.Tgt -and $LVN[$e.Id] -ge 2) { $nn.Add($e.Id) } }
    $doc.not_neutralizable = [object[]]$nn.ToArray()
    if ($Tool -ceq 'find-ads') {
      $ads = New-SaOList
      foreach ($x in $AD) { $ads.Add([ordered]@{ mediator = $x[0]; network = $x[1]; files = [int]$x[2] }) }
      $doc.mediation = [ordered]@{ adapters = [object[]]$ads.ToArray() }
    }
    $Holder.Out = (ConvertTo-Json -Depth 10 -InputObject $doc).Replace("`r`n", "`n")
    return
  }

  # ---- text --------------------------------------------------------------------------------------
  $SECT = New-SaList; $SECM = New-SaList; $SECC = New-Object 'System.Collections.Generic.List[int]'; $SECH = New-Object 'System.Collections.Generic.List[bool]'; $SECF = New-Object 'System.Collections.Generic.List[bool]'
  $ROWS = New-SaOList              # per section: List of row keys
  $ROWT = New-SaSDict; $ROWA = New-SaSDict; $ROWREL = New-SaSDict; $ROWLN = New-SaSDict
  $sec = {
    param([string]$Title, [string]$Mode, [int]$Cap, [bool]$HintOnly)
    $SECT.Add($Title); $SECM.Add($Mode); $SECC.Add($Cap); $SECH.Add($HintOnly); $SECF.Add($false); $ROWS.Add((New-SaList))
    return ($SECT.Count - 1)
  }
  $row = {
    param([int]$Sx, [string]$Rel, [string]$Ln, [string]$Text, [string]$Ann)
    $k = [string]$Sx + $SUB + $Rel + $SUB + $Ln
    if (-not $ROWT.ContainsKey($k)) { $ROWS[$Sx].Add($k); $ROWT[$k] = $Text; $ROWA[$k] = ''; $ROWREL[$k] = $Rel; $ROWLN[$k] = $Ln }
    if ($Ann.Length -gt 0) {
      $cur = $ROWA[$k]
      if ((' ' + $cur + ' ').IndexOf(' ' + $Ann + ' ', [StringComparison]::Ordinal) -lt 0) { if ($cur.Length -eq 0) { $ROWA[$k] = $Ann } else { $ROWA[$k] = $cur + ' ' + $Ann } }
    }
  }
  $crow = { param([int]$Sx, [int]$I, [string]$Ann) & $row $Sx $CRl[$I] $CLn[$I] ((& $pathOf $CRl[$I]) + ':' + $CLn[$I] + ':' + (& $txtOf $CRl[$I] $CLn[$I])) $Ann }
  $rrow = { param([int]$Sx, [int]$I, [string]$Ann) & $row $Sx $RR[$I] $RL[$I] ((& $pathOf $RR[$I]) + ':' + $RL[$I] + ':' + (& $txtOf $RR[$I] $RL[$I])) $Ann }
  $mrow = { param([int]$Sx, [int]$I, [string]$Ann) $tx = ''; if ($MTXT.ContainsKey($MNL[$I])) { $tx = $MTXT[$MNL[$I]] }; & $row $Sx ([string][char]1) $MNL[$I] ($MANDISP + ':' + $MNL[$I] + ':' + $tx) $Ann }
  $drow = { param([int]$Sx, [int]$I, [string]$Ann) & $row $Sx $DR[$I] $DL[$I] ((& $pathOf $DR[$I]) + ':' + $DL[$I] + ':' + (& $txtOf $DR[$I] $DL[$I])) $Ann }
  $hrow = { param([int]$Sx, [int]$I) & $row $Sx $HER[$I] $HEL[$I] ((& $pathOf $HER[$I]) + ':' + $HEL[$I] + ':' + (& $txtOf $HER[$I] $HEL[$I])) '' }
  $aspect = { param([string]$A) return ($selAll -or $selAsp.Contains($A)) }
  $mname = { param([string]$Api) return $Api.Substring($Api.LastIndexOf([char]'#') + 1) }
  $simple = { param([string]$C) return (Get-SaLastSeg $C) }
  $rolLabel = New-SaSDict
  foreach ($ro in $rolesL) { $rolLabel[$ro[0]] = $ro[1] }
  $FBC = New-SaSDict; $FCT = New-SaOList; $FMT = New-SaOList
  foreach ($x in $fmtL) {
    if ($x[0] -ceq 'by_class') { $FBC[$x[1]] = $x[2] }
    elseif ($x[0] -ceq 'by_class_token') { $FCT.Add(@($x[1], $x[2])) }
    elseif ($x[0] -ceq 'by_method_token') { $FMT.Add(@($x[1], $x[2])) }
  }
  $fmtc = {
    param([string]$C, [string]$M, [bool]$UseM)
    $sc = Get-SaLastSeg $C
    if ($FBC.ContainsKey($sc)) { if ($FBC[$sc] -ceq '-') { return '' }; return $FBC[$sc] }
    foreach ($x in $FCT) { if ($sc.IndexOf($x[0], [StringComparison]::Ordinal) -ge 0) { return $x[1] } }
    if ($UseM) { foreach ($x in $FMT) { if ($M.IndexOf($x[0], [StringComparison]::Ordinal) -ge 0) { return $x[1] } } }
    return ''
  }
  $mkmiss = {
    param([string]$S)
    $l = New-SaList
    if ((& $n0 $IDF $S) -gt 0) { foreach ($mk in (& $mkOf $S)) { if (-not $MKF.ContainsKey($S + $SUB + $mk)) { $l.Add($mk) } } }
    if ($l.Count -eq 0) { return '' }
    return ' (marker class missing: ' + [string]::Join(',', $l.ToArray()) + ')'
  }
  $hasadroot = { param([string]$S) foreach ($x in $rootsL) { if ($x[1] -ceq 'ad' -and $x[2] -ceq $S) { return $true } }; return $false }
  # hint_rows(flag, title, sx): app-code and manifest hint rows of the hints with that flag and
  # title; returns the lowercased tokens (underscores removed) of those hints
  $hintRows = {
    param([string]$Flag, [string]$Title, [int]$Sx)
    $toks = New-SaList
    foreach ($h in $hintsL) {
      $id = $h[0]
      if ($h[1] -cne $Flag -or $h[4] -cne $Title) { continue }
      foreach ($x in $htokL) { if ($x[0] -ceq $id) { foreach ($w in (Split-SaWs ($x[1].ToLowerInvariant().Replace('_', '')))) { $toks.Add($w) } } }
      if ($noHints) { continue }
      for ($j = 0; $j -lt $nhe; $j++) { if ($HEI[$j] -ceq $id) { & $hrow $Sx $j } }
      for ($j = 0; $j -lt $nmn; $j++) { if (((& $mhints $j) + ' ').IndexOf(' ' + $id + ' ', [StringComparison]::Ordinal) -ge 0) { & $mrow $Sx $j '' } }
    }
    return ,$toks.ToArray()
  }
  $hintSections = {
    param([string]$Flag, [string]$Skip)
    $seen = New-SaSet
    foreach ($h in $hintsL) {
      if ($h[1] -cne $Flag) { continue }
      if ($Skip.IndexOf(' ' + $h[4] + ' ', [StringComparison]::Ordinal) -ge 0 -or $seen.Contains($h[4])) { continue }
      [void]$seen.Add($h[4])
      $sx = & $sec $h[4] 'always' 0 $true
      $null = & $hintRows $Flag $h[4] $sx
    }
  }
  $manSections = {
    param([string]$Tc, [string]$Tp, [string]$Tm)
    for ($k = 1; $k -le 3; $k++) {
      $tt = $Tm; if ($k -eq 1) { $tt = $Tc } elseif ($k -eq 2) { $tt = $Tp }
      $sx = & $sec ('AndroidManifest' + $sep + $tt) 'always' 0 $false
      for ($j = 0; $j -lt $nmn; $j++) {
        $tag = $MNT[$j]
        if ($k -eq 1) { $ok = ($tag -ceq 'activity' -or $tag -ceq 'activity-alias' -or $tag -ceq 'service' -or $tag -ceq 'receiver' -or $tag -ceq 'provider' -or $tag -ceq 'action') }
        elseif ($k -eq 2) { $ok = ($tag -ceq 'uses-permission' -or $tag -ceq 'permission') }
        else { $ok = ($tag -ceq 'meta-data') }
        if (-not $ok) { continue }
        foreach ($s in (Split-SaWs $MSD[$j])) { if (& $ING $s) { & $mrow $sx $j $s } }
      }
      $null = & $hintRows 'manifest' ('AndroidManifest' + $sep + $tt) $sx
    }
  }

  foreach ($e in $ents) {
    $s = $e.Id
    if (-not $e.Ing) { continue }
    if (-not ($selIds.Contains($s) -or ($selAll -and $LVN[$s] -gt 0))) { continue }
    $PRE = $e.Pre
    $sx = & $sec ($PRE + $sep + 'Identity') 'always' 0 $false
    $nz = 'no (detection-only)'; if ($e.Tgt) { $nz = 'yes' }
    & $row $sx '' '0' ('# confidence=' + $LV[$s] + ' status=' + $ST[$s] + ' neutralizable=' + $nz + ' detail=' + $DET[$s] + (& $mkmiss $s)) ''
    foreach ($x in $RC) {
      if ($x[0] -cne $s) { continue }
      $t = 'identity: package '; if ($x[1] -ceq 'ns') { $t = 'namespace: package ' } elseif ($x[1] -ceq 'ad') { $t = 'adapter: package ' }
      & $row $sx $x[4] '0' ((& $pathOf $x[4]) + ':0:' + $t + $x[2] + ' (' + $x[3] + ' files)') ''
    }
    foreach ($mk in (& $mkOf $s)) { $kf = $s + $SUB + $mk; if ($MKF.ContainsKey($kf)) { & $row $sx $MKF[$kf] '0' ((& $pathOf $MKF[$kf]) + ':0:identity: marker class ' + $mk) '' } }
    foreach ($ro in $rolesL) {
      $sx = & $sec ($PRE + $sep + $rolLabel[$ro[0]]) 'nonempty' 0 $false
      for ($j = 0; $j -lt $nc; $j++) {
        if ($CS[$j] -ceq $s -and $CRo[$j] -ceq $ro[0]) { $q = '?'; if ($CF[$j] -ceq 'exact') { $q = '' }; & $crow $sx $j ((& $simple $CA[$j]) + $q) }
      }
    }
    $sx = & $sec ($PRE + $sep + 'Manifest') 'nonempty' 0 $false
    for ($j = 0; $j -lt $nmn; $j++) { if ($MSD[$j].IndexOf(' ' + $s + ' ', [StringComparison]::Ordinal) -ge 0) { & $mrow $sx $j '' } }
    $sx = & $sec ($PRE + $sep + 'Endpoints') 'nonempty' 0 $false
    for ($j = 0; $j -lt $nd; $j++) { if ($DS[$j] -ceq $s -and $DK[$j] -ceq 'E' -and $DE[$j] -ceq '1') { & $drow $sx $j $DV[$j] } }
    $sx = & $sec ($PRE + $sep + 'Ad Unit IDs') 'nonempty' 0 $false
    for ($j = 0; $j -lt $nd; $j++) {
      if ($DS[$j] -ceq $s -and $DK[$j] -ceq 'I' -and $DE[$j] -ceq '1') {
        $lbl = ''
        foreach ($x in $idpfxL) { if ($x[0] -ceq $s -and $x[1] -ceq $DV[$j]) { $lbl = $x[2] } }
        & $drow $sx $j $lbl
      }
    }
    $cap = 50; if ($full) { $cap = 0 }
    $sx = & $sec ($PRE + $sep + 'References') 'nonempty' $cap $false
    for ($j = 0; $j -lt $nr; $j++) { if ($RSD[$j] -ceq $s) { & $rrow $sx $j '' } }
    for ($j = 0; $j -lt $nc; $j++) { if ($CS[$j] -ceq $s) { & $crow $sx $j '' } }
  }
  if ($Tool -ceq 'find-trackers') {
    if (& $aspect 'generic') { & $hintSections 'generic' '' }
    if (& $aspect 'endpoints') {
      $sx = & $sec 'Known Tracker Endpoints' 'always' 0 $false
      for ($j = 0; $j -lt $nd; $j++) { if ((& $ING $DS[$j]) -and $DK[$j] -ceq 'E' -and $DE[$j] -ceq '1') { & $drow $sx $j $DS[$j] } }
      $null = & $hintRows 'endpoints' 'Known Tracker Endpoints' $sx
      & $hintSections 'endpoints' ' Known Tracker Endpoints '
    }
    if (& $aspect 'manifest') { & $manSections 'Tracker Services & Receivers' 'Tracker Permissions' 'Tracker Meta-data' }
  } else {
    if (& $aspect 'formats') {
      $fs = @('banner', 'interstitial', 'rewarded', 'native', 'rewarded_interstitial', 'app_open')
      $ttl = @('Banner', 'Interstitial', 'Rewarded', 'Native', 'Rewarded Interstitial', 'App Open')
      $fsx = @{}
      for ($f = 0; $f -lt 6; $f++) { $fsx[$fs[$f]] = & $sec ('Cross-SDK' + $sep + 'All ' + $ttl[$f] + ' Patterns') 'always' 0 $false }
      for ($j = 0; $j -lt $nc; $j++) {
        if ((& $GRPOF $CS[$j]) -ceq 'ads') {
          # like fmtcm(CA, mname(CA)) of the sh twin: the "simple name" is taken from the whole
          # Class#method string
          $api = $CA[$j]
          $x = & $fmtc $api (& $mname $api) $true
          if ($x.Length -gt 0 -and $fsx.ContainsKey($x)) { & $crow $fsx[$x] $j $CS[$j] }
        }
      }
      for ($j = 0; $j -lt $nr; $j++) {
        if ((& $GRPOF $RSD[$j]) -ceq 'ads') {
          foreach ($a in (Split-SaWs $RK[$j])) {
            if ($a -ceq '-') { continue }
            $x = & $fmtc $a '' $false
            if ($x.Length -gt 0 -and $fsx.ContainsKey($x)) { & $rrow $fsx[$x] $j $RSD[$j] }
          }
        }
      }
      $sx = & $sec ('Cross-SDK' + $sep + 'Ad Unit / Placement IDs') 'always' 0 $false
      for ($j = 0; $j -lt $nd; $j++) { if ((& $ING $DS[$j]) -and $DK[$j] -ceq 'I' -and $DE[$j] -ceq '1') { & $drow $sx $j $DS[$j] } }
      $null = & $hintRows 'formats' ('Cross-SDK' + $sep + 'Ad Unit / Placement IDs') $sx
      & $hintSections 'formats' (' Cross-SDK' + $sep + 'Ad Unit / Placement IDs ')
    }
    if (& $aspect 'mediation') {
      foreach ($e in $ents) {
        $s = $e.Id; $m = $false
        foreach ($x in $RC) { if ($x[0] -ceq $s -and $x[1] -ceq 'ad') { $m = $true } }
        if (-not $m -and -not (& $hasadroot $s)) { continue }
        $sx = & $sec ('Mediation' + $sep + $e.Disp + ' Mediation Adapters') 'always' 0 $false
        foreach ($x in $AD) { if ($x[0] -ceq $s) { & $row $sx $x[3] '0' ((& $pathOf $x[3]) + ':0:adapter: ' + $x[1] + ' (' + $x[2] + ' files)') '' } }
      }
      & $hintSections 'mediation' ''
    }
    if (& $aspect 'consent') {
      $sx = & $sec ('Consent' + $sep + 'Google UMP / Funding Choices') 'always' 0 $false
      foreach ($e in $ents) {
        $s = $e.Id
        if ($e.Grp -cne 'consent') { continue }
        foreach ($x in $RC) { if ($x[0] -ceq $s) { & $row $sx $x[4] '0' ((& $pathOf $x[4]) + ':0:identity: package ' + $x[2] + ' (' + $x[3] + ' files) [' + $s + ']') '' } }
        foreach ($mk in (& $mkOf $s)) { $kf = $s + $SUB + $mk; if ($MKF.ContainsKey($kf)) { & $row $sx $MKF[$kf] '0' ((& $pathOf $MKF[$kf]) + ':0:identity: marker class ' + $mk) '' } }
        for ($j = 0; $j -lt $nr; $j++) { if ($RSD[$j] -ceq $s) { & $rrow $sx $j ($s + '/ref') } }
        for ($j = 0; $j -lt $nc; $j++) {
          if ($CS[$j] -ceq $s -and ($CRo[$j] -ceq 'consent' -or $CRo[$j] -ceq 'config')) { $q = '?'; if ($CF[$j] -ceq 'exact') { $q = '' }; & $crow $sx $j ($s + '/' + $CRo[$j] + $q) }
        }
      }
      $sx = & $sec ('Consent' + $sep + 'IAB TCF v2') 'always' 0 $false
      $null = & $hintRows 'consent' ('Consent' + $sep + 'IAB TCF v2') $sx
      $sx = & $sec ('Consent' + $sep + 'COPPA / Child-Directed') 'always' 0 $false
      $cop = & $hintRows 'consent' ('Consent' + $sep + 'COPPA / Child-Directed') $sx
      for ($j = 0; $j -lt $nc; $j++) {
        if ($CRo[$j] -cne 'consent') { continue }
        $low = (& $mname $CA[$j]).ToLowerInvariant()
        foreach ($tk in $cop) { if ($low.IndexOf($tk, [StringComparison]::Ordinal) -ge 0) { & $crow $sx $j ($CS[$j] + '/' + (& $GRPOF $CS[$j])); break } }
      }
      $sx = & $sec ('Consent' + $sep + 'SDK-specific Opt-out') 'always' 0 $false
      for ($j = 0; $j -lt $nc; $j++) { if ($CRo[$j] -ceq 'consent' -and (& $GRPOF $CS[$j]) -cne 'consent') { & $crow $sx $j ($CS[$j] + '/' + (& $GRPOF $CS[$j])) } }
      $null = & $hintRows 'consent' ('Consent' + $sep + 'SDK-specific Opt-out') $sx
      & $hintSections 'consent' (' Consent' + $sep + 'IAB TCF v2 Consent' + $sep + 'COPPA / Child-Directed Consent' + $sep + 'SDK-specific Opt-out ')
    }
    if (& $aspect 'manifest') { & $manSections 'Ad Activities & Services' 'Ad Permissions' 'Ad Meta-data' }
  }
  if (& $aspect 'entrypoints') {
    $sx = & $sec ('Entry Points' + $sep + $toolTitle + ' SDK calls from app code (library packages excluded)') 'always' 0 $false
    $SECF[$sx] = $true
    & $epCollect
    for ($i = 0; $i -lt $EPR.Count; $i++) {
      $k = $EPR[$i] + $SUB + $EPL[$i]
      & $row $sx $EPR[$i] $EPL[$i] ((& $pathOf $EPR[$i]) + ':' + $EPL[$i] + ':' + (& $txtOf $EPR[$i] $EPL[$i])) $EPA[$k]
    }
  }
  if ($Tool -ceq 'find-trackers') { $note = 'If no results appear, tracker SDKs may only be initialized internally (e.g., via ContentProvider).' }
  else { $note = 'If no results appear, ad SDKs may only be invoked internally via mediation adapters.' }
  for ($i = 0; $i -lt $SECT.Count; $i++) {
    if ($SECH[$i] -and $noHints) { continue }
    $keys = $ROWS[$i]
    $n = $keys.Count
    if ($n -eq 0 -and $SECM[$i] -ceq 'nonempty') { continue }
    $out.Add(''); $out.Add('==== ' + $SECT[$i] + ' ===='); $out.Add('')
    if ($n -eq 0) { $out.Add('') }
    $sk = New-SaList; $sm = New-SaSDict
    foreach ($k in $keys) {
      $kk = $ROWREL[$k] + "`0" + ([long]$ROWLN[$k]).ToString('D12')
      $sk.Add($kk); $sm[$kk] = $k
    }
    $cap = $SECC[$i]
    $c = 0
    foreach ($kk in (Get-SaSortedOrdinal $sk)) {
      $c++
      if ($cap -gt 0 -and $c -gt $cap) { $out.Add('... ' + ($n - $cap) + ' more row(s) (use --full)'); break }
      $k = $sm[$kk]
      $t = $ROWT[$k]
      if ($ROWA[$k].Length -gt 0) { $t = $t + '  [' + $ROWA[$k] + ']' }
      $out.Add($t)
    }
    if ($SECF[$i]) {
      $out.Add('')
      $out.Add('NOTE: Only calls from app code are shown above. Library-internal calls are excluded.')
      $out.Add($note)
    }
  }
  $out.Add('')
  $out.Add('=== Search complete ===')
  $Holder.Out = [string]::Join("`n", $out.ToArray())
}

function Get-SaRootDir([string]$Rel, [string]$Np, [string]$R) {
  # rootdir: the directory (relative to the input) of root R, from a file of package Np under it
  $ls = $Rel.LastIndexOf([char]'/')
  $d = ''
  if ($ls -ge 0) { $d = $Rel.Substring(0, $ls) }
  $k = (Get-SaNseg $Np) - (Get-SaNseg $R)
  for ($i = 0; $i -lt $k; $i++) {
    $ls = $d.LastIndexOf([char]'/')
    if ($ls -lt 0) { $d = ''; break }
    $d = $d.Substring(0, $ls)
  }
  return $d
}
