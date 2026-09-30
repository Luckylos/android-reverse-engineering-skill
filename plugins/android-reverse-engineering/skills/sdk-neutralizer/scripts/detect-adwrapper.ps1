# detect-adwrapper.ps1 - Heuristically detect a PUBLISHER'S IN-HOUSE ad/analytics
# mediation wrapper in an apktool-decoded APK: the app-owned layer that calls the
# network ad SDKs (or serves house/WebView ads) on the app's behalf.
#
# Why this exists: registry-scan.py neutralizes each KNOWN third-party network SDK
# (AdMob, AppLovin, IronSource, ...). But some publishers ship their own wrapper
# (e.g. Rovio's com.rovio.beacon in Bad Piggies, Guru's guru.ads.fusion) that
# drives those SDKs AND can serve direct WebView/MRAID "house" interstitials with
# NO third-party SDK involved. Neutralizing every network SDK does not stop that
# house-ad path. This detector spots such a wrapper so the user is told the
# network-SDK neutralization may be incomplete, and is pointed at the discovery
# workflow (SKILL.md Phases 3b/3c) or a dedicated registry entry.
#
# DETECTION ONLY: nothing in the decoded directory is modified. Output is
# informational and the script always exits 0 (unless arguments are invalid).
#
# Same heuristic, exclusion lists and output as detect-adwrapper.sh; keep the
# two in sync. PowerShell 5.1 compatible.
#
# The registry is read with registry-lib.ps1 (Get-RegistryPackages -Lenient: only
# the "packages" arrays, the same rows as registry-query.sh packages). A registry
# that cannot be read only costs the registry exclusions: a warning goes to stderr
# and the check still runs and exits 0.
#
# Exit codes:
#   0 - check completed (informational), also when the registry is unreadable
#   1 - error (invalid input, unknown option)
param(
    [Parameter(Position=0)]
    [string]$DecodedDir,
    [string]$Registry,
    [switch]$DumpExclusions,
    [Alias('h')]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$script:CallerOutputEncoding = $null
try {
    $script:CallerOutputEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
} catch { }
try {

function Show-Usage {
    Write-Host @"
Usage: detect-adwrapper.ps1 <decoded-dir> [OPTIONS]

Heuristically detect a publisher's in-house ad/analytics mediation wrapper in a
directory decoded by decode-apk.ps1 (apktool output). Detection only: nothing is
modified.

Arguments:
  <decoded-dir>     Directory containing AndroidManifest.xml and smali*\

Options:
  -Registry <dir>   SDK registry directory (default: <script-dir>\..\registry).
                    Used to exclude known third-party SDK packages (only the
                    "packages" arrays are read).
  -DumpExclusions   Debug: print the exclusion set (EXCL:<root>, sorted) and the
                    in-house wrapper map (INHOUSE:<root>|<sdk_id>, lookup order),
                    then exit 0. No <decoded-dir> needed.
  -Help             Show this help message

Output:
  ADWRAPPER_DETECTED:<package>:<high|medium|low>:<evidence,...>
  ADWRAPPER_SUMMARY:<none|candidate>

  evidence keys: adclasses=N,networks=<a+b+..>,webview=<yes|no>,mraid=<yes|no>,
                 analytics=<yes|no>,vendor=<yes|no>[,registry=<sdk_id>]

Exit codes: 0 = check completed (informational), 1 = error
"@
}

if ($Help) { Show-Usage; exit 0 }

if (-not $DumpExclusions) {
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
}
if (-not $Registry) {
    $Registry = Join-Path (Split-Path -Parent $PSCommandPath) '..\registry'
}

# =====================================================================
# FROZEN legacy table - see tests/unit/t_network_roots.sh (identical, same order,
# in detect-adwrapper.sh; each root is covered by a registry entry).
# Known ad-network / analytics SDK package roots: "root|label".
# =====================================================================
$networkRoots = @(
    'com/applovin|applovin'
    'com/google/android/gms/ads|admob'
    'com/google/ads|admob'
    'com/unity3d|unity'
    'com/ironsource|ironsource'
    'com/mbridge|mintegral'
    'com/vungle|vungle'
    'com/adcolony|adcolony'
    'com/facebook/ads|meta'
    'com/chartboost|chartboost'
    'com/inmobi|inmobi'
    'com/bytedance|pangle'
    'com/fyber|fyber'
    'com/smaato|smaato'
    'com/tapjoy|tapjoy'
    'com/mopub|mopub'
    'com/pubmatic|pubmatic'
    'com/moloco|moloco'
    'com/mobilefuse|mobilefuse'
    'io/bidmachine|bidmachine'
    'net/pubnative|pubnative'
    'com/amazon/device/ads|amazon'
    'com/yandex/mobile/ads|yandex'
    'com/ogury|ogury'
    'io/presage|ogury'
)

# FROZEN legacy table - see tests/unit/t_network_roots.sh (identical, same order,
# in detect-adwrapper.sh).
# Common libraries + ad-tech infrastructure that are NOT publisher-owned wrappers.
$commonRoots = @(
    'android','androidx','kotlin','kotlinx','com/google','com/squareup',
    'okhttp3','okio','retrofit2','retrofit','com/jakewharton','dagger','javax',
    'io/reactivex','com/bumptech','com/airbnb','org/json','org/intellij',
    'org/jetbrains','org/apache','org/chromium','org/checkerframework','org/slf4j',
    'bolts','com/github','com/facebook','com/amazon','com/iab/omid','com/safedk',
    'sg/bigo','com/bykv','com/explorestack','gatewayprotocol','com/five_corp',
    'com/gameanalytics','com/localytics','com/singular','com/nefta','com/tiktok',
    'com/microsoft','io/ktor','io/branch','io/appmetrica','coil','zendesk',
    'cz/msebera','com/caverock','com/yahoo','com/moat','com/adjust','com/appsflyer',
    'com/mixpanel','com/braze','com/clevertap','com/yandex','j$'
)

# =====================================================================
# Registry: third-party-SDK exclusion + in_house_wrapper package map, from the
# "packages" arrays only (registry-lib.ps1, lenient: unreadable entry files are
# skipped with a WARN). The in-house map is an ORDERED list (sdk_id ordinal, then
# file order, like registry-query packages): the first match wins, as in the sh twin.
# =====================================================================
$regExcl = New-Object System.Collections.Generic.List[string]
$inhouseMap = New-Object System.Collections.Generic.List[object]   # {Pkg (slash), Id}
$regOk = $false
try {
    . (Join-Path $PSScriptRoot 'registry-lib.ps1')
    $regRes = Get-RegistryPackages -Registry $Registry -Lenient
    foreach ($m in @($regRes.Messages)) { [Console]::Error.Write([string]$m + "`n") }
    if ($regRes.ExitCode -eq 0) {
        foreach ($it in $regRes.Items) {
            $pkg = [string]$it.Package
            if ($pkg -eq '' -or $pkg -eq '-') { continue }
            $slp = $pkg.Replace('.', '/')
            if ($it.InHouse) {
                $inhouseMap.Add([pscustomobject]@{ Pkg = $slp; Id = [string]$it.SdkId })
            } else {
                $regExcl.Add($slp)
            }
        }
        $regOk = $true
    }
} catch {
    [Console]::Error.Write("registry-lib: $($_.Exception.Message)`n")
}
if (-not $regOk) {
    $regExcl.Clear(); $inhouseMap.Clear()
    [Console]::Error.Write("[WARN] registry unreadable: registry exclusions skipped`n")
}

# Full exclusion set (unique, ordinal order = LC_ALL=C sort -u of the sh twin)
$exclSet = New-Object 'System.Collections.Generic.SortedSet[string]' ([System.StringComparer]::Ordinal)
foreach ($nr in $networkRoots) { [void]$exclSet.Add($nr.Split('|')[0]) }
foreach ($c in $commonRoots) { [void]$exclSet.Add($c) }
foreach ($r in $regExcl) { if ($r -ne '') { [void]$exclSet.Add($r) } }
$excl = @($exclSet)

if ($DumpExclusions) {
    $dump = New-Object System.Collections.Generic.List[string]
    foreach ($e in $excl) { $dump.Add("EXCL:$e") }
    foreach ($ih in $inhouseMap) { $dump.Add("INHOUSE:$($ih.Pkg)|$($ih.Id)") }
    foreach ($l in $dump) { Write-Host $l }
    exit 0
}

function Test-Excluded {
    param([string]$Pkg)
    foreach ($e in $excl) {
        if ($Pkg -eq $e -or $Pkg.StartsWith("$e/")) { return $true }
        if ($e.StartsWith("$Pkg/")) { return $true }
    }
    return $false
}
function Get-InhouseId {
    param([string]$Pkg)
    foreach ($ih in $inhouseMap) {
        $p = $ih.Pkg
        if ($Pkg -eq $p -or $Pkg.StartsWith("$p/") -or $p.StartsWith("$Pkg/")) { return $ih.Id }
    }
    return ''
}

# =====================================================================
# App package + vendor root (top 2 segments)
# =====================================================================
$manifestText = [System.IO.File]::ReadAllText($manifest, [System.Text.Encoding]::UTF8)
$appPkg = ''
$mP = [regex]::Match($manifestText, '<manifest[^>]+package="([^"]*)"')
if ($mP.Success) { $appPkg = $mP.Groups[1].Value }
$appSl = $appPkg -replace '\.', '/'
$vseg = $appSl.Split('/')
if ($vseg.Count -ge 2) { $vroot = "$($vseg[0])/$($vseg[1])" } else { $vroot = $appSl }

# =====================================================================
# smali dirs
# =====================================================================
$smaliDirs = @(Get-ChildItem -LiteralPath $root -Directory -Filter 'smali*' -ErrorAction SilentlyContinue |
    ForEach-Object { $_.FullName } | Sort-Object)

Write-Host "=== In-house ad/analytics wrapper check (detection only): $root ==="

if ($smaliDirs.Count -eq 0) {
    Write-Host "No smali/ directory found - nothing to scan."
    Write-Host "ADWRAPPER_SUMMARY:none"
    exit 0
}

$adNameRe = [regex]'([Aa]ds?[A-Z]|AdManager|AdsSdk|Mediation|Interstitial|Rewarded|[Bb]anner|AdView|AdLoader|AdUnit|AdConfig|AdNetwork|AdServer|AdProvider|Advert)'
$anNameRe = [regex]'(Tracking|Analytics|Attribution|Beacon|Telemetry)'

# =====================================================================
# 1. Candidate roots: 3-segment (or shorter) package roots that contain an
#    ad-shaped OR analytics-shaped class.
# =====================================================================
$candSet = New-Object System.Collections.Generic.HashSet[string]
foreach ($s in $smaliDirs) {
    $slen = $s.Length + 1
    foreach ($f in [System.IO.Directory]::EnumerateFiles($s, '*.smali', [System.IO.SearchOption]::AllDirectories)) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($f)
        if (-not ($adNameRe.IsMatch($name) -or $anNameRe.IsMatch($name))) { continue }
        $rel = $f.Substring($slen) -replace '\\', '/'
        $dir = $rel.Substring(0, $rel.LastIndexOf('/'))
        $parts = $dir.Split('/')
        if ($parts.Count -ge 3) { $r3 = "$($parts[0])/$($parts[1])/$($parts[2])" } else { $r3 = $dir }
        [void]$candSet.Add($r3)
    }
}
$candidates = @($candSet | Sort-Object)

# =====================================================================
# 2. Score each surviving candidate
# =====================================================================
$flagged = New-Object System.Collections.Generic.List[object]  # {Pkg, Conf, Ev}

foreach ($R in $candidates) {
    if (Test-Excluded $R) { continue }

    # collect this root's smali files across all smali dirs
    $rfiles = New-Object System.Collections.Generic.List[string]
    foreach ($s in $smaliDirs) {
        $rd = Join-Path $s ($R -replace '/', '\')
        if (Test-Path -LiteralPath $rd -PathType Container) {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($rd, '*.smali', [System.IO.SearchOption]::AllDirectories)) {
                $rfiles.Add($f)
            }
        }
    }
    if ($rfiles.Count -eq 0) { continue }

    # single content pass: networks, webview, mraid
    $foundNets = New-Object System.Collections.Generic.HashSet[string]
    $wv = 'no'; $mr = 'no'
    foreach ($f in $rfiles) {
        $text = [System.IO.File]::ReadAllText($f)
        if ($wv -eq 'no' -and $text.Contains('Landroid/webkit/WebView')) { $wv = 'yes' }
        if ($mr -eq 'no' -and $text.IndexOf('mraid', [StringComparison]::OrdinalIgnoreCase) -ge 0) { $mr = 'yes' }
        foreach ($nrl in $networkRoots) {
            $nr = $nrl.Split('|')[0]
            if ($R -eq $nr -or $R.StartsWith("$nr/")) { continue }
            if (-not $foundNets.Contains($nr) -and $text.Contains("L$nr")) { [void]$foundNets.Add($nr) }
        }
    }
    # dedup labels, preserve networkRoots order
    $netlabels = @()
    foreach ($nrl in $networkRoots) {
        $parts = $nrl.Split('|'); $nr = $parts[0]; $label = $parts[1]
        if ($foundNets.Contains($nr) -and ($netlabels -notcontains $label)) { $netlabels += $label }
    }
    $netcount = $netlabels.Count

    # ad / analytics class counts (by basename)
    $adn = 0; $ann = 0
    foreach ($f in $rfiles) {
        $b = [System.IO.Path]::GetFileName($f)
        if ($adNameRe.IsMatch($b)) { $adn++ }
        if ($anNameRe.IsMatch($b)) { $ann++ }
    }

    $wmc = ($wv -eq 'yes' -and $mr -eq 'yes')

    # vendor match
    $vm = 'no'
    if ($R -eq $vroot -or $R.StartsWith("$vroot/")) { $vm = 'yes' }

    # flag decision
    if ($netcount -lt 2 -and -not $wmc) { continue }

    # confidence
    $conf = 'low'
    if ($wmc -and $adn -ge 1) { $conf = 'medium' }
    if ($netcount -ge 2) { $conf = 'medium' }
    if ((($vm -eq 'yes') -and (($netcount -ge 2) -or $wmc)) -or (($netcount -ge 2) -and $wmc)) {
        $conf = 'high'
    }

    $pkgDot = $R -replace '/', '.'
    if ($netlabels.Count -gt 0) { $netStr = ($netlabels -join '+') } else { $netStr = '-' }
    $anStr = if ($ann -ge 1) { 'yes' } else { 'no' }
    $ev = "adclasses=$adn,networks=$netStr,webview=$wv,mraid=$mr,analytics=$anStr,vendor=$vm"
    $reg = Get-InhouseId $R
    if ($reg) { $ev = "$ev,registry=$reg" }

    $flagged.Add([pscustomobject]@{ Pkg = $pkgDot; Conf = $conf; Ev = $ev })
}

# =====================================================================
# Report (high, then medium, then low)
# =====================================================================
function Emit-Conf {
    param([string]$Want)
    foreach ($e in $script:flagged) {
        if ($e.Conf -ne $Want) { continue }
        Write-Host "ADWRAPPER_DETECTED:$($e.Pkg):$($e.Conf):$($e.Ev)"
        if ($e.Ev -match 'registry=([^,]+)') {
            Write-Host "  -> in-house wrapper '$($e.Pkg)' [$($e.Conf)] - already has a registry entry ($($Matches[1])); make sure that entry is applied."
        } else {
            Write-Host "  -> in-house wrapper candidate '$($e.Pkg)' [$($e.Conf)] - no registry entry; the network-SDK neutralization may not fully stop ads."
        }
    }
}

$summary = 'none'
if ($flagged.Count -gt 0) {
    $summary = 'candidate'
    Emit-Conf 'high'
    Emit-Conf 'medium'
    Emit-Conf 'low'
}
Write-Host "ADWRAPPER_SUMMARY:$summary"

if ($summary -eq 'candidate') {
    Write-Host ''
    Write-Host "Note: this app appears to carry a publisher's own in-house ad/analytics wrapper"
    Write-Host "(a layer that drives the network ad SDKs, or serves house/WebView ads, itself)."
    Write-Host "Neutralizing the third-party network SDKs from the registry may NOT fully stop ads"
    Write-Host "(a house/WebView ad path can survive). Consider adding a dedicated registry entry for"
    Write-Host "the package above, or run the unknown-SDK discovery pass (SKILL.md Phases 3b/3c) on it."
} else {
    Write-Host "No in-house ad/analytics wrapper detected (network-SDK neutralization from the registry should suffice)."
}
exit 0

} finally {
    if ($script:CallerOutputEncoding) {
        try { [Console]::OutputEncoding = $script:CallerOutputEncoding } catch { }
    }
}
