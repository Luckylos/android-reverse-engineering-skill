# detect-protection.ps1 - Detect anti-tamper / integrity / licensing protection
# in an apktool-decoded APK, so the user knows BEFORE a rebuild that a
# re-signed APK of a protected app will not run.
#
# DETECTION ONLY: nothing in the decoded directory is modified, and the
# neutralizer never removes, disables or works around a protection.
#
# What it looks for (same as detect-protection.sh): Google Play automatic
# protection (PairIP, seen in protected apps), the Play Licensing library (LVL),
# Play Integrity and SafetyNet clients (public Google package names), and
# packed or hidden app code detected generically (components declared in the
# manifest that are missing from the decoded code). No vendor list is used.
#
# Exit codes:
#   0 - check completed (whatever it found: the result is informational)
#   1 - error (invalid input, unknown option)
param(
    [Parameter(Position=0)]
    [string]$DecodedDir,
    [Alias('h')]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
# UTF-8 output so captured paths keep non-ASCII characters
$script:CallerOutputEncoding = $null
try {
    $script:CallerOutputEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
} catch { }
# The whole script runs inside this try: the caller's console encoding is
# restored in the matching finally at the end, including on every 'exit'.
try {

function Show-Usage {
    Write-Host @"
Usage: detect-protection.ps1 <decoded-dir> [OPTIONS]

Detect anti-tamper, integrity and licensing protection in a directory decoded
by decode-apk.ps1 (apktool output). Detection only: nothing is modified.

Arguments:
  <decoded-dir>     Directory containing AndroidManifest.xml and smali*\

Options:
  -Help             Show this help message

Output:
  PROTECTION_DETECTED:<id>:<category>:<high|medium|low>:<evidence>[,<evidence>...]
  PROTECTION_SUMMARY:<none|integrity|license|hardener|signature-vm>

Categories (the summary is the most severe one found):
  signature-vm - Google Play PairIP with signature check / encrypted VM code:
                 a re-signed APK does not start
  hardener     - packed or hidden app code (declared components absent from the
                 decoded code): a re-signed APK does not start
  license      - license gate (PairIP license check, LVL): the app may stop at
                 a "get this app from Play" screen or refuse to run
  integrity    - Play Integrity / SafetyNet client: the app starts, a backend
                 enforcing the verdict may refuse it (often benign SDK usage)

Exit codes: 0 = check completed (informational), 1 = error
"@
}

if ($Help) { Show-Usage; exit 0 }

if (-not $DecodedDir) {
    Write-Host "Error: No decoded directory specified." -ForegroundColor Red
    Show-Usage
    exit 1
}
if (-not (Test-Path -LiteralPath $DecodedDir -PathType Container)) {
    Write-Host "Error: Not a directory: $DecodedDir" -ForegroundColor Red
    exit 1
}
$root = (Resolve-Path -LiteralPath $DecodedDir).ProviderPath.TrimEnd('\', '/')
$manifest = Join-Path $root 'AndroidManifest.xml'
if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
    Write-Host "Error: $root has no AndroidManifest.xml (not an apktool-decoded directory?)" -ForegroundColor Red
    exit 1
}

# Ordinal sort, like LC_ALL=C sort in the bash script (stable output)
function Get-OrdinalSorted {
    param([string[]]$Items)
    if (-not $Items -or $Items.Count -eq 0) { return @() }
    $arr = [string[]]$Items
    [Array]::Sort($arr, [StringComparer]::Ordinal)
    return $arr   # unrolled: callers collect it with @()
}
function Get-Rel {
    param([string]$Path)
    return $Path.Substring($script:root.Length + 1)
}

# smali, smali_classes2..N, smali_assets
$smaliDirs = @(Get-OrdinalSorted @(Get-ChildItem -LiteralPath $root -Directory -Filter 'smali*' |
    ForEach-Object { $_.FullName }))

# Files can sit in lib\, in assets\ (packers load their code from there) or in
# unknown\ (apktool's bucket for files outside the standard APK layout)
$allFiles = @()
foreach ($r in @('lib', 'assets', 'unknown')) {
    $rp = Join-Path $root $r
    if (Test-Path -LiteralPath $rp -PathType Container) {
        $allFiles += @(Get-ChildItem -LiteralPath $rp -Recurse -File -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName })
    }
}
$allFiles = @(Get-OrdinalSorted $allFiles)

# All android:name values of the manifest (application, components, permissions)
$manifestText = [System.IO.File]::ReadAllText($manifest, [System.Text.Encoding]::UTF8)
$nameList = New-Object System.Collections.Generic.List[string]
foreach ($m in [regex]::Matches($manifestText, 'android:name="([^"]*)"')) {
    $v = $m.Groups[1].Value
    if (-not $nameList.Contains($v)) { $nameList.Add($v) }
}
$manifestNames = @(Get-OrdinalSorted $nameList.ToArray())

$maxEvidence = 5

# =====================================================================
# Rules - id|category|confidence|kind|pattern (see detect-protection.sh for
# the kinds and the source of every rule; keep both tables identical).
# Packed code is not a rule: it is the generic Test-PackedCode below.
# =====================================================================
$rules = @(
    'pairip-license|license|high|manifest|com.pairip.application.Application'
    'pairip-license|license|high|manifest|com.pairip.licensecheck.'
    'pairip-license|license|high|class|com/pairip/licensecheck/LicenseClient'
    'pairip-license|license|high|class|com/pairip/licensecheck/LicenseContentProvider'
    'pairip-signature-vm|signature-vm|high|class|com/pairip/SignatureCheck'
    'pairip-signature-vm|signature-vm|high|class|com/pairip/VMRunner'
    'pairip-signature-vm|signature-vm|high|class|com/pairip/VmDecryptor'
    'pairip-signature-vm|signature-vm|high|file|libpairipcore.so'
    'lvl|license|medium|class|com/google/android/vending/licensing'
    'play-integrity|integrity|low|class|com/google/android/play/core/integrity'
    'safetynet|integrity|low|class|com/google/android/gms/safetynet'
)

$ids = New-Object System.Collections.Generic.List[string]       # ordered, unique
$categoryOf = @{}
$found = New-Object System.Collections.Generic.List[object]     # {Id, Conf, Detail}

function Add-Evidence {
    param([string]$Id, [string]$Conf, [string]$Detail)
    $script:found.Add([pscustomobject]@{ Id = $Id; Conf = $Conf; Detail = $Detail })
}
function Test-Found {
    param([string]$Id)
    foreach ($e in $script:found) { if ($e.Id -eq $Id) { return $true } }
    return $false
}
# Relative evidence paths use '/' like the bash script (identical output)
function Get-RelSlash { param([string]$Path) return ((Get-Rel $Path) -replace '\\', '/') }

# Expand a 'path' glob one segment at a time (wildcards allowed in every
# segment). -Filter/-Path would also treat [ ] in the decoded dir as wildcards.
function Resolve-GlobPath {
    param([string]$Base, [string]$Pattern)
    $current = @($Base)
    foreach ($seg in $Pattern.Split('/')) {
        $next = @()
        foreach ($c in $current) {
            if (-not (Test-Path -LiteralPath $c -PathType Container)) { continue }
            if ($seg -match '[*?]') {
                $next += @(Get-ChildItem -LiteralPath $c -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -clike $seg } | ForEach-Object { $_.FullName })
            } else {
                $p = Join-Path $c $seg
                if (Test-Path -LiteralPath $p) { $next += $p }
            }
        }
        $current = $next
    }
    return @(Get-OrdinalSorted $current)
}

foreach ($rule in $rules) {
    $f = $rule.Split('|')
    $id = $f[0]; $cat = $f[1]; $conf = $f[2]; $kind = $f[3]; $pat = $f[4]
    if (-not $ids.Contains($id)) { $ids.Add($id); $categoryOf[$id] = $cat }
    switch ($kind) {
        'manifest' {
            $n = 0
            foreach ($nm in $manifestNames) {
                if ($nm.StartsWith($pat, [StringComparison]::Ordinal)) {
                    Add-Evidence $id $conf "manifest=$nm"
                    $n++; if ($n -ge $maxEvidence) { break }
                }
            }
        }
        'class' {
            # First match only: the same package is often split across several classesN.dex
            $winPat = $pat -replace '/', '\'
            foreach ($s in $smaliDirs) {
                $file = Join-Path $s ($winPat + '.smali')
                $dir = Join-Path $s $winPat
                if (Test-Path -LiteralPath $file -PathType Leaf) {
                    Add-Evidence $id $conf ("class=" + (Get-RelSlash $file)); break
                } elseif (Test-Path -LiteralPath $dir -PathType Container) {
                    Add-Evidence $id $conf ("class=" + (Get-RelSlash $dir) + '/'); break
                }
            }
        }
        'file' {
            $n = 0
            foreach ($af in $allFiles) {
                if ([System.IO.Path]::GetFileName($af) -clike $pat) {
                    Add-Evidence $id $conf ("file=" + (Get-RelSlash $af))
                    $n++; if ($n -ge $maxEvidence) { break }
                }
            }
        }
        'path' {
            $n = 0
            foreach ($p in (Resolve-GlobPath $root $pat)) {
                Add-Evidence $id $conf ("path=" + (Get-RelSlash $p))
                $n++; if ($n -ge $maxEvidence) { break }
            }
        }
    }
}

# Packed or hidden app code: a packer ships a stub and keeps the real classes
# in an encrypted payload, so most components declared in the manifest have no
# class in the decoded smali. Clean apps miss only a few. Needs >= 3 declared
# classes and >= 3 missing; >= 50% missing -> medium, >= 80% -> high.
function Test-PackedCode {
    $id = 'packed-code'
    if ($script:smaliDirs.Count -eq 0) { return }
    $present = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($sd in $script:smaliDirs) {
        $prefixLen = $sd.TrimEnd('\', '/').Length + 1
        foreach ($f in [System.IO.Directory]::EnumerateFiles($sd, '*.smali', [System.IO.SearchOption]::AllDirectories)) {
            [void]$present.Add(($f.Substring($prefixLen, $f.Length - $prefixLen - 6) -replace '\\', '/'))
        }
    }
    # activity-alias is not matched (its name is not a class); android.* classes
    # belong to the framework and are never in the APK.
    $pkg = ''
    $declared = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($m in [regex]::Matches($script:manifestText, '<(manifest|application|activity|service|receiver|provider)[\s][^>]*>')) {
        if ($m.Groups[1].Value -eq 'manifest') {
            $pm = [regex]::Match($m.Value, 'package="([^"]*)"')
            if ($pm.Success) { $pkg = $pm.Groups[1].Value }
            continue
        }
        $nm = [regex]::Match($m.Value, 'android:name="([^"]*)"')
        if (-not $nm.Success) { continue }
        $n = $nm.Groups[1].Value
        if ($n.StartsWith('.')) { $n = $pkg + $n } elseif ($n.IndexOf('.') -lt 0) { $n = $pkg + '.' + $n }
        if ($n.StartsWith('android.', [StringComparison]::Ordinal)) { continue }
        [void]$declared.Add($n.Replace('.', '/'))
    }
    $missing = @(Get-OrdinalSorted @($declared | Where-Object { -not $present.Contains($_) }))
    $total = $declared.Count
    $miss = $missing.Count
    if ($total -lt 3 -or $miss -lt 3) { return }
    $pct = [int][math]::Floor($miss * 100 / $total)
    $conf = ''
    if ($pct -ge 80) { $conf = 'high' } elseif ($pct -ge 50) { $conf = 'medium' }
    if (-not $conf) { return }
    if (-not $script:ids.Contains($id)) { $script:ids.Add($id); $script:categoryOf[$id] = 'hardener' }
    Add-Evidence $id $conf "declared-classes-missing=$miss/$total"
    foreach ($c in ($missing | Select-Object -First 3)) { Add-Evidence $id $conf "absent=$c" }
}
Test-PackedCode

$names = @{
    'pairip-signature-vm' = 'Google Play automatic protection (PairIP: signature check + encrypted VM code)'
    'pairip-license'      = 'Google Play automatic protection (PairIP: license check only)'
    'lvl'                 = 'Google Play Licensing library (LVL)'
    'packed-code'         = 'a packer: app code hidden in a payload (declared components missing from the decoded code)'
    'play-integrity'      = 'Play Integrity API client'
    'safetynet'           = 'SafetyNet Attestation client'
}
function Get-CatRank {
    param([string]$C)
    switch ($C) { 'signature-vm' { return 4 } 'hardener' { return 3 } 'license' { return 2 } 'integrity' { return 1 } default { return 0 } }
}
function Get-ConfRank {
    param([string]$C)
    switch ($C) { 'high' { return 3 } 'medium' { return 2 } 'low' { return 1 } default { return 0 } }
}

# =====================================================================
# Report
# =====================================================================
Write-Host "=== Protection check (detection only): $root ==="
$summary = 'none'
$blockers = @()
$blockerConf = ''
foreach ($id in $ids) {
    if (-not (Test-Found $id)) { continue }
    # PairIP: the signature/VM variant already implies the license check; report
    # it once, with the license evidence folded in.
    if ($id -eq 'pairip-license' -and (Test-Found 'pairip-signature-vm')) { continue }
    $cat = $categoryOf[$id]
    $conf = ''
    $evidence = @()
    $sources = @($id)
    if ($id -eq 'pairip-signature-vm') { $sources += 'pairip-license' }
    foreach ($src in $sources) {   # the id's own evidence first
        foreach ($e in $found) {
            if ($e.Id -ne $src) { continue }
            if ((Get-ConfRank $e.Conf) -gt (Get-ConfRank $conf)) { $conf = $e.Conf }
            if ($evidence.Count -lt $maxEvidence) { $evidence += $e.Detail }
        }
    }
    Write-Host "PROTECTION_DETECTED:${id}:${cat}:${conf}:$($evidence -join ',')"
    Write-Host "  -> $($names[$id]) [$cat, $conf confidence]"
    if ((Get-CatRank $cat) -gt (Get-CatRank $summary)) { $summary = $cat }
    if ($cat -eq 'signature-vm' -or $cat -eq 'hardener') {
        $blockers += $names[$id]
        if (-not $blockerConf -or (Get-ConfRank $conf) -lt (Get-ConfRank $blockerConf)) { $blockerConf = $conf }
    }
}
Write-Host "PROTECTION_SUMMARY:$summary"

switch ($summary) {
    { $_ -eq 'signature-vm' -or $_ -eq 'hardener' } {
        Write-Host ''
        Write-Host "!!! WARNING: this app is protected by $($blockers -join ', ')." -ForegroundColor Red
        if ($blockerConf -eq 'high') {
            Write-Host '!!! A rebuilt and re-signed APK will NOT run:' -ForegroundColor Red
        } else {
            Write-Host '!!! A rebuilt and re-signed APK will most likely NOT run (medium-confidence match):' -ForegroundColor Red
        }
        Write-Host '!!! the protection checks the signing certificate and/or hides its code in an encrypted payload loaded at startup.' -ForegroundColor Red
        Write-Host '!!! Neutralization can still produce a report, but the rebuilt APK will not be usable.' -ForegroundColor Red
        Write-Host '!!! The neutralizer does not remove or bypass protections. Tell the user before spending' -ForegroundColor Red
        Write-Host '!!! time on a rebuild.' -ForegroundColor Red
    }
    'license' {
        Write-Host ''
        Write-Host '!!! WARNING: this app has a Google Play license gate. A rebuilt and re-signed APK may stop at' -ForegroundColor Yellow
        Write-Host "!!! a 'Get this app from Play' screen or refuse to run. Tell the user before a rebuild." -ForegroundColor Yellow
    }
    'integrity' {
        Write-Host 'Note: Play Integrity / SafetyNet client code found (often bundled by SDKs). The app starts;'
        Write-Host 'a backend that enforces the verdict may refuse the re-signed APK (login, purchases, online play).'
    }
    'none' {
        Write-Host 'No PairIP, Google licensing/integrity client or packed code detected (this does not rule out'
        Write-Host 'an app-specific protection that hides nothing from the decoded tree).'
    }
}
exit 0

} finally {
    if ($script:CallerOutputEncoding) {
        try { [Console]::OutputEncoding = $script:CallerOutputEncoding } catch { }
    }
}
