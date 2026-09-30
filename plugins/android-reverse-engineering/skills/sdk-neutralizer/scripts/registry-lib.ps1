# registry-lib.ps1 -- PowerShell 5.1 reader of the SDK registry (DESIGN 4.5).
# Twin of registry-query.sh / registry-query.jq; registry-query.ps1 is the thin CLI.
#
# FUNCTION DEFINITIONS ONLY: no param() block, no top-level statement, no global or
# script state, and no change to Set-StrictMode, $ErrorActionPreference or
# [Console]::OutputEncoding outside the functions. Dot-source it into the caller's
# script scope:   . (Join-Path $PSScriptRoot 'registry-lib.ps1')
# (dot-sourcing a script that has a param() block would overwrite the caller's
# variables of the same name, e.g. $Registry of detect-adwrapper.ps1).
#
# Public functions (each returns ONE result object: ExitCode 0|1, Messages = the
# stderr lines of registry-query, Items = the rows as objects, sorted like the sh twin):
#   Get-RegistryRows     -Registry DIR [-Lenient]  Items: SdkId, Category, Field, Value
#   Get-RegistryShared   -Registry DIR             Items: Kind, Key, Value
#   Get-RegistryPackages -Registry DIR [-Lenient]  Items: SdkId, InHouse (bool), Package
#   Test-RegistryFile    -Path FILE [-RequireSdkId $true|$false]
#                        -> Ok, Message, Data (ConvertFrom-Json object), SdkId
#   Resolve-RegistryDir  -Registry DIR -DefaultDir DIR  (explicit > $env:SDK_REGISTRY_DIR > default)
#   Get-LongPath / ConvertFrom-LongPath  \\?\ and \\?\UNC\ long-path prefixes
#   ConvertTo-RegistryTsvField  jq @tsv escaping (backslash first, then TAB, LF, CR)
# Values follow the jq program: null or "" -> '-', booleans -> true/false.
# Integrity messages are identical to the sh twin (see registry-query.sh).
# ASCII-only source.

function Get-LongPath {
  # Absolute path with the Win32 long-path prefix: \\?\C:\... or \\?\UNC\server\share\...
  # (a plain \\?\ in front of a UNC root does not work: "invalid file name syntax").
  param([string]$Path)
  if ($Path.StartsWith('\\?\')) { return $Path }
  $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
  $full = [System.IO.Path]::GetFullPath($full)
  if ($full.StartsWith('\\')) { return ('\\?\UNC\' + $full.Substring(2)) }
  return ('\\?\' + $full)
}

function ConvertFrom-LongPath {
  # Remove the prefix added by Get-LongPath (for printing).
  param([string]$Path)
  if ($Path.StartsWith('\\?\UNC\')) { return ('\\' + $Path.Substring(8)) }
  if ($Path.StartsWith('\\?\')) { return $Path.Substring(4) }
  return $Path
}

function Resolve-RegistryDir {
  param([string]$Registry, [string]$DefaultDir)
  if (-not [string]::IsNullOrEmpty($Registry)) { return $Registry }
  $envDir = [Environment]::GetEnvironmentVariable('SDK_REGISTRY_DIR')
  if (-not [string]::IsNullOrEmpty($envDir)) { return $envDir }
  return $DefaultDir
}

function ConvertTo-RegistryTsvField {
  param([string]$Value)
  return $Value.Replace('\', '\\').Replace("`t", '\t').Replace("`n", '\n').Replace("`r", '\r')
}

function Format-RegistryValue {
  # jq `nz`: null or "" -> '-', booleans lowercase, anything else as text
  param($Value)
  if ($null -eq $Value) { return '-' }
  if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
  $s = [string]$Value
  if ($s.Length -eq 0) { return '-' }
  return $s
}

function Test-RegistryObject {
  param($Value)
  return ($Value -is [System.Management.Automation.PSCustomObject])
}

function Test-RegistryProperty {
  # case-SENSITIVE property test (PSObject.Properties matches names case-insensitively)
  param($Object, [string]$Name)
  if (-not (Test-RegistryObject $Object)) { return $false }
  $p = $Object.PSObject.Properties[$Name]
  return ($null -ne $p -and $p.Name -ceq $Name)
}

function Get-RegistryProperty {
  param($Object, [string]$Name)
  if (-not (Test-RegistryObject $Object)) { return $null }
  $p = $Object.PSObject.Properties[$Name]
  if ($null -eq $p -or $p.Name -cne $Name) { return $null }
  return ,$p.Value
}

function Get-RegistryArray {
  # jq `arr(.name)`: the elements when the property is an array, otherwise nothing
  param($Object, [string]$Name)
  $v = Get-RegistryProperty $Object $Name
  if ($v -is [array]) { return ,$v }
  return ,@()
}

function Get-RegistryObjectProperty {
  # jq `obj(.name)`: the property when it is an object, otherwise $null (= {})
  param($Object, [string]$Name)
  $v = Get-RegistryProperty $Object $Name
  if (Test-RegistryObject $v) { return $v }
  return $null
}

function ConvertTo-RegistryAsciiLower {
  # jq ascii_downcase: only A-Z are folded
  param([string]$Text)
  $c = $Text.ToCharArray()
  for ($i = 0; $i -lt $c.Length; $i++) {
    $n = [int]$c[$i]
    if ($n -ge 65 -and $n -le 90) { $c[$i] = [char]($n + 32) }
  }
  return (New-Object string (,$c))
}

function Get-RegistryCaseCollision {
  # First key (ASCII-lowercased) that appears with different case in one object, in
  # the order of the jq program: objects in pre-order, colliding keys of one object
  # in ordinal order. $Node comes from JavaScriptSerializer (dictionaries, object[]).
  param($Node)
  if ($Node -is [System.Collections.IDictionary]) {
    $count = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::Ordinal)
    $dups = New-Object 'System.Collections.Generic.List[string]'
    foreach ($k in $Node.Keys) {
      $l = ConvertTo-RegistryAsciiLower ([string]$k)
      if ($count.ContainsKey($l)) {
        if ($count[$l] -eq 1) { $dups.Add($l) }
        $count[$l] = $count[$l] + 1
      } else { $count[$l] = 1 }
    }
    if ($dups.Count -gt 0) {
      $a = $dups.ToArray()
      [Array]::Sort($a, [StringComparer]::Ordinal)
      return $a[0]
    }
    foreach ($v in $Node.Values) {
      $r = Get-RegistryCaseCollision $v
      if ($null -ne $r) { return $r }
    }
  } elseif ($Node -is [System.Collections.IList]) {
    foreach ($v in $Node) {
      $r = Get-RegistryCaseCollision $v
      if ($null -ne $r) { return $r }
    }
  }
  return $null
}

function Test-RegistryMultiDocument {
  # True when $Text is a sequence of two or more JSON values (jq reads them as
  # several documents; the .NET parser only reports "invalid JSON primitive").
  param([string]$Text, $Serializer)
  $segments = New-Object 'System.Collections.Generic.List[string]'
  $i = 0
  $n = $Text.Length
  while ($true) {
    while ($i -lt $n -and (' ', "`t", "`r", "`n") -contains [string]$Text[$i]) { $i++ }
    if ($i -ge $n) { break }
    $start = $i
    $c = $Text[$i]
    if ($c -eq [char]'{' -or $c -eq [char]'[') {
      $depth = 0
      $inStr = $false
      while ($i -lt $n) {
        $ch = $Text[$i]
        if ($inStr) {
          if ($ch -eq [char]'\') { $i++ }
          elseif ($ch -eq [char]'"') { $inStr = $false }
        } elseif ($ch -eq [char]'"') { $inStr = $true }
        elseif ($ch -eq [char]'{' -or $ch -eq [char]'[') { $depth++ }
        elseif ($ch -eq [char]'}' -or $ch -eq [char]']') {
          $depth--
          if ($depth -eq 0) { $i++; break }
        }
        $i++
      }
      if ($depth -ne 0) { return $false }
    } elseif ($c -eq [char]'"') {
      $i++
      $closed = $false
      while ($i -lt $n) {
        $ch = $Text[$i]
        if ($ch -eq [char]'\') { $i += 2; continue }
        $i++
        if ($ch -eq [char]'"') { $closed = $true; break }
      }
      if (-not $closed) { return $false }
    } else {
      while ($i -lt $n -and -not ((' ', "`t", "`r", "`n", '{', '}', '[', ']', '"', ',', ':') -contains [string]$Text[$i])) { $i++ }
      if ($i -eq $start) { return $false }
    }
    $segments.Add($Text.Substring($start, $i - $start))
  }
  if ($segments.Count -lt 2) { return $false }
  foreach ($s in $segments) {
    try { [void]$Serializer.DeserializeObject($s) } catch { return $false }
  }
  return $true
}

function Test-RegistryFile {
  # Integrity of one registry file, in the order of the sh twin: unreadable, BOM, empty file,
  # invalid JSON / more than one document, root not an object, case-colliding keys,
  # then (entries only) sdk_id and targets: null.
  param([string]$Path, [bool]$RequireSdkId = $true)
  $ErrorActionPreference = 'Stop'
  Set-StrictMode -Version 2.0
  $res = [pscustomobject]@{ Ok = $false; Message = ''; Data = $null; SdkId = $null }
  # an unreadable file (access denied, locked, I/O error) is a per-file problem like
  # the others (sh twin: [ -r ]), so --lenient skips just this file
  $bytes = $null
  try { $bytes = [System.IO.File]::ReadAllBytes($Path) } catch { $bytes = $null }
  if ($null -eq $bytes) { $res.Message = 'unreadable file'; return $res }
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $res.Message = 'BOM not allowed'; return $res
  }
  $text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes)
  if ($text.Trim([char[]]@([char]32, [char]9, [char]13, [char]10)).Length -eq 0) {
    $res.Message = 'empty file'; return $res
  }
  $data = $null
  $parsed = $false
  try {
    $data = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    $parsed = $true
  } catch {
    $parsed = $false
  }
  if (-not $parsed) {
    # Diagnose with the serializer behind ConvertFrom-Json: it accepts keys that
    # differ only by case, which ConvertFrom-Json rejects.
    Add-Type -AssemblyName System.Web.Extensions
    $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $js.MaxJsonLength = [int]::MaxValue
    $js.RecursionLimit = 1024
    $raw = $null
    $ok = $true
    try { $raw = $js.DeserializeObject($text) } catch { $ok = $false }
    if (-not $ok) {
      if (Test-RegistryMultiDocument $text $js) { $res.Message = 'more than one JSON document' }
      else { $res.Message = 'invalid JSON' }
      return $res
    }
    if ($raw -isnot [System.Collections.IDictionary]) { $res.Message = 'root is not an object'; return $res }
    $k = Get-RegistryCaseCollision $raw
    if ($null -ne $k) { $res.Message = 'case-colliding keys: ' + $k } else { $res.Message = 'invalid JSON' }
    return $res
  }
  if (-not (Test-RegistryObject $data)) { $res.Message = 'root is not an object'; return $res }
  if ($RequireSdkId) {
    $id = Get-RegistryProperty $data 'sdk_id'
    if ($id -isnot [string] -or $id.Length -eq 0) { $res.Message = 'sdk_id missing or not a string'; return $res }
    if ((Test-RegistryProperty $data 'targets') -and $null -eq (Get-RegistryProperty $data 'targets')) {
      $res.Message = 'targets is null'; return $res
    }
    $res.SdkId = $id
  }
  $res.Ok = $true
  $res.Data = $data
  return $res
}

function Read-RegistrySet {
  # Shared loader of the three verbs. $Mode: rows | packages | shared.
  param([string]$Registry, [bool]$Lenient, [string]$Mode)
  $ErrorActionPreference = 'Stop'
  Set-StrictMode -Version 2.0
  $msgs = New-Object 'System.Collections.Generic.List[string]'
  $set = [pscustomobject]@{ ExitCode = 1; Messages = $msgs; Entries = $null; Shared = $null }
  $shownDir = $Registry
  if ($shownDir.Length -gt 1) { $shownDir = $shownDir.TrimEnd([char[]]@([char]'/', [char]'\')) }
  if ($shownDir.Length -eq 0) { $shownDir = $Registry }
  $dir = Get-LongPath $Registry
  if (-not [System.IO.Directory]::Exists($dir)) {
    $msgs.Add('registry-query: ERROR registry directory not found: ' + $shownDir); return $set
  }
  $names = New-Object 'System.Collections.Generic.List[string]'
  foreach ($p in [System.IO.Directory]::GetFiles($dir)) {
    $nm = [System.IO.Path]::GetFileName($p)
    if (-not $nm.EndsWith('.json', [StringComparison]::Ordinal)) { continue }
    if ($nm.StartsWith('_') -or $nm.StartsWith('.')) { continue }
    $names.Add($nm)
  }
  $sorted = $names.ToArray()
  [Array]::Sort($sorted, [StringComparer]::Ordinal)
  $sharedName = '_audit-shared.json'
  if ($Mode -ne 'packages') {
    $sp = [System.IO.Path]::Combine($dir, $sharedName)
    if (-not [System.IO.File]::Exists($sp)) {
      $msgs.Add('registry-query: ERROR ' + $sharedName + ': file not found in ' + $shownDir); return $set
    }
  }
  if ($Mode -ne 'shared' -and $sorted.Length -eq 0) {
    $msgs.Add('registry-query: ERROR no registry entries in ' + $shownDir); return $set
  }
  if ($Mode -ne 'packages') {
    $r = Test-RegistryFile -Path $sp -RequireSdkId $false
    if (-not $r.Ok) { $msgs.Add('registry-query: ERROR ' + $sharedName + ': ' + $r.Message); return $set }
    $set.Shared = $r.Data
  }
  if ($Mode -eq 'shared') { $set.ExitCode = 0; return $set }
  $owner = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
  $good = New-Object 'System.Collections.Generic.List[object]'
  $problems = New-Object 'System.Collections.Generic.List[string]'
  foreach ($nm in $sorted) {
    $r = Test-RegistryFile -Path ([System.IO.Path]::Combine($dir, $nm)) -RequireSdkId $true
    if (-not $r.Ok) { $problems.Add($nm + ': ' + $r.Message); continue }
    if ($owner.ContainsKey($r.SdkId)) {
      $problems.Add($nm + ': duplicate sdk_id ' + $r.SdkId + ' (also in ' + $owner[$r.SdkId] + ')'); continue
    }
    $owner[$r.SdkId] = $nm
    $good.Add([pscustomobject]@{ File = $nm; SdkId = $r.SdkId; Data = $r.Data })
  }
  if ($problems.Count -gt 0) {
    foreach ($m in $problems) {
      if ($Lenient) { $msgs.Add('registry-query: WARN skipping ' + $m) } else { $msgs.Add('registry-query: ERROR ' + $m) }
    }
    if (-not $Lenient) { return $set }
  }
  if ($good.Count -eq 0) { $msgs.Add('registry-query: ERROR no valid entries in ' + $shownDir); return $set }
  # ordinal sdk_id order (jq sort_by); sdk_ids are unique here
  # ([Array]::Sort(keys, items, ...) would sort a converted COPY of an object[] items)
  $byId = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
  foreach ($g in $good) { $byId[$g.SdkId] = $g }
  $keys = New-Object 'string[]' $good.Count
  $byId.Keys.CopyTo($keys, 0)
  [Array]::Sort($keys, [StringComparer]::Ordinal)
  $vals = New-Object 'object[]' $keys.Length
  for ($i = 0; $i -lt $keys.Length; $i++) { $vals[$i] = $byId[$keys[$i]] }
  $set.Entries = $vals
  $set.ExitCode = 0
  return $set
}

function Get-RegistryGroup {
  # jq group_of: first group of category_groups whose array contains the category
  param($Category, $Groups)
  if ($Category -is [string] -and (Test-RegistryObject $Groups)) {
    foreach ($g in $Groups.PSObject.Properties) {
      if ($g.Value -is [array]) {
        foreach ($c in $g.Value) { if ($c -is [string] -and $c -ceq $Category) { return $g.Name } }
      }
    }
  }
  return 'other'
}

function Get-RegistryRows {
  param([string]$Registry, [switch]$Lenient)
  $ErrorActionPreference = 'Stop'
  Set-StrictMode -Version 2.0
  $set = Read-RegistrySet -Registry $Registry -Lenient ([bool]$Lenient) -Mode 'rows'
  $items = New-Object 'System.Collections.Generic.List[object]'
  $res = [pscustomobject]@{ ExitCode = $set.ExitCode; Messages = $set.Messages; Items = $items }
  if ($set.ExitCode -ne 0) { return $res }
  $cg = Get-RegistryObjectProperty $set.Shared 'category_groups'
  foreach ($e in $set.Entries) {
    $d = $e.Data
    $id = Format-RegistryValue (Get-RegistryProperty $d 'sdk_id')
    $catRaw = Get-RegistryProperty $d 'category'
    $cat = Format-RegistryValue $catRaw
    $t = Get-RegistryObjectProperty $d 'targets'
    $det = Get-RegistryObjectProperty $d 'detection'
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $rows.Add(@('file', $e.File))
    $rows.Add(@('display_name', (Get-RegistryProperty $d 'display_name')))
    $rows.Add(@('vendor', (Get-RegistryProperty $d 'vendor')))
    $rows.Add(@('group', (Get-RegistryGroup $catRaw $cg)))
    $ihw = Get-RegistryProperty $d 'in_house_wrapper'
    $rows.Add(@('in_house_wrapper', ($ihw -is [bool] -and $ihw)))
    $rows.Add(@('has_targets', (Test-RegistryProperty $d 'targets')))
    foreach ($v in (Get-RegistryArray $d 'packages')) { $rows.Add(@('package', $v)) }
    foreach ($v in (Get-RegistryArray $det 'extra_packages')) { $rows.Add(@('extra_package', $v)) }
    foreach ($v in (Get-RegistryArray $det 'exclude_packages')) { $rows.Add(@('exclude_package', $v)) }
    foreach ($v in (Get-RegistryArray $det 'namespace_roots')) { $rows.Add(@('namespace_root', $v)) }
    foreach ($v in (Get-RegistryArray $det 'adapter_packages')) { $rows.Add(@('adapter_package', $v)) }
    foreach ($v in (Get-RegistryArray $det 'marker_classes')) { $rows.Add(@('marker_class', $v)) }
    foreach ($kind in @('entry_points', 'ad_operations')) {
      $label = 'entry_point'
      if ($kind -eq 'ad_operations') { $label = 'ad_operation' }
      foreach ($ct in (Get-RegistryArray $t $kind)) {
        if (-not (Test-RegistryObject $ct)) { continue }
        $c = Format-RegistryValue (Get-RegistryProperty $ct 'class')
        foreach ($m in (Get-RegistryArray $ct 'methods')) {
          if (-not (Test-RegistryObject $m)) { continue }
          $rows.Add(@('target_api', ($c + ' ' + (Format-RegistryValue (Get-RegistryProperty $m 'name')) + ' ' + $label)))
        }
      }
    }
    foreach ($a in (Get-RegistryArray $det 'apis')) {
      if (-not (Test-RegistryObject $a)) { continue }
      $c = Format-RegistryValue (Get-RegistryProperty $a 'class')
      $role = Format-RegistryValue (Get-RegistryProperty $a 'role')
      foreach ($m in (Get-RegistryArray $a 'methods')) {
        $rows.Add(@('api', ($c + ' ' + (Format-RegistryValue $m) + ' ' + $role)))
      }
    }
    foreach ($mc in (Get-RegistryArray $d 'manifest_components')) {
      if (-not (Test-RegistryObject $mc)) { continue }
      $rows.Add(@('manifest_component', (Get-RegistryProperty $mc 'class')))
    }
    foreach ($v in (Get-RegistryArray $det 'manifest_names')) { $rows.Add(@('manifest_name', $v)) }
    foreach ($v in (Get-RegistryArray $det 'domains')) { $rows.Add(@('domain', $v)) }
    foreach ($ip in (Get-RegistryArray $det 'id_prefixes')) {
      if (-not (Test-RegistryObject $ip)) { continue }
      $rows.Add(@('id_prefix', ((Format-RegistryValue (Get-RegistryProperty $ip 'prefix')) + ' ' + (Format-RegistryValue (Get-RegistryProperty $ip 'label')))))
    }
    foreach ($r in $rows) {
      $items.Add([pscustomobject]@{ SdkId = $id; Category = $cat; Field = $r[0]; Value = (Format-RegistryValue $r[1]) })
    }
  }
  return $res
}

function Get-RegistryPackages {
  param([string]$Registry, [switch]$Lenient)
  $ErrorActionPreference = 'Stop'
  Set-StrictMode -Version 2.0
  $set = Read-RegistrySet -Registry $Registry -Lenient ([bool]$Lenient) -Mode 'packages'
  $items = New-Object 'System.Collections.Generic.List[object]'
  $res = [pscustomobject]@{ ExitCode = $set.ExitCode; Messages = $set.Messages; Items = $items }
  if ($set.ExitCode -ne 0) { return $res }
  foreach ($e in $set.Entries) {
    $d = $e.Data
    $id = Format-RegistryValue (Get-RegistryProperty $d 'sdk_id')
    $ihw = Get-RegistryProperty $d 'in_house_wrapper'
    $ih = ($ihw -is [bool] -and $ihw)
    foreach ($p in (Get-RegistryArray $d 'packages')) {
      $items.Add([pscustomobject]@{ SdkId = $id; InHouse = $ih; Package = (Format-RegistryValue $p) })
    }
  }
  return $res
}

function Format-RegistryPair {
  # jq fpair: "[a, b]" -> "a b"
  param($Value)
  if ($Value -is [array]) {
    $a = $null
    $b = $null
    if ($Value.Length -gt 0) { $a = $Value[0] }
    if ($Value.Length -gt 1) { $b = $Value[1] }
    return ((Format-RegistryValue $a) + ' ' + (Format-RegistryValue $b))
  }
  return (Format-RegistryValue $Value)
}

function Get-RegistryShared {
  param([string]$Registry)
  $ErrorActionPreference = 'Stop'
  Set-StrictMode -Version 2.0
  $set = Read-RegistrySet -Registry $Registry -Lenient $false -Mode 'shared'
  $items = New-Object 'System.Collections.Generic.List[object]'
  $res = [pscustomobject]@{ ExitCode = $set.ExitCode; Messages = $set.Messages; Items = $items }
  if ($set.ExitCode -ne 0) { return $res }
  foreach ($prop in $set.Shared.PSObject.Properties) {
    $k = $prop.Name
    $v = $prop.Value
    if ($k -ceq 'category_groups' -or $k -ceq 'tool_groups') {
      $kind = 'category_group'
      if ($k -ceq 'tool_groups') { $kind = 'tool_group' }
      if (Test-RegistryObject $v) {
        foreach ($g in $v.PSObject.Properties) {
          if ($g.Value -is [array]) {
            foreach ($x in $g.Value) { $items.Add([pscustomobject]@{ Kind = $kind; Key = (Format-RegistryValue $g.Name); Value = (Format-RegistryValue $x) }) }
          }
        }
      }
    } elseif ($k -ceq 'section_separator') {
      $items.Add([pscustomobject]@{ Kind = 'section_separator'; Key = '-'; Value = (Format-RegistryValue $v) })
    } elseif ($k -ceq 'legacy_flags') {
      if (Test-RegistryObject $v) {
        foreach ($tool in $v.PSObject.Properties) {
          if ($tool.Value -isnot [array]) { continue }
          foreach ($f in $tool.Value) {
            if (-not (Test-RegistryObject $f)) { continue }
            $val = (Format-RegistryValue (Get-RegistryProperty $f 'flag')) + ' ' + (Format-RegistryValue (Get-RegistryProperty $f 'sdk_id')) + ' ' +
                   (Format-RegistryValue (Get-RegistryProperty $f 'label')) + ' ' + (Format-RegistryValue (Get-RegistryProperty $f 'section_prefix'))
            $items.Add([pscustomobject]@{ Kind = 'legacy_flag'; Key = (Format-RegistryValue $tool.Name); Value = $val })
          }
        }
      }
    } elseif ($k -ceq 'role_labels') {
      if (Test-RegistryObject $v) {
        foreach ($r in $v.PSObject.Properties) { $items.Add([pscustomobject]@{ Kind = 'role_label'; Key = (Format-RegistryValue $r.Name); Value = (Format-RegistryValue $r.Value) }) }
      }
    } elseif ($k -ceq 'format_by_class' -or $k -ceq 'format_by_class_token' -or $k -ceq 'format_by_method_token') {
      $fkey = $k.Substring(7)
      if ($v -is [array]) {
        foreach ($x in $v) { $items.Add([pscustomobject]@{ Kind = 'format_token'; Key = $fkey; Value = (Format-RegistryPair $x) }) }
      }
    } elseif ($k -ceq 'format_none') {
      if ($v -is [array]) {
        foreach ($x in $v) { $items.Add([pscustomobject]@{ Kind = 'format_token'; Key = 'none'; Value = (Format-RegistryValue $x) }) }
      }
    } elseif ($k -ceq 'library_roots') {
      if ($v -is [array]) {
        foreach ($x in $v) { $items.Add([pscustomobject]@{ Kind = 'library_root'; Key = '-'; Value = (Format-RegistryValue $x) }) }
      }
    } elseif ($k -ceq 'hints') {
      if ($v -is [array]) {
        foreach ($h in $v) {
          if (-not (Test-RegistryObject $h)) { continue }
          $hid = Format-RegistryValue (Get-RegistryProperty $h 'id')
          $meta = $hid + ' ' + (Format-RegistryValue (Get-RegistryProperty $h 'tool')) + ' ' + (Format-RegistryValue (Get-RegistryProperty $h 'flag')) + ' ' +
                  (Format-RegistryValue (Get-RegistryProperty $h 'scope')) + ' ' + (Format-RegistryValue (Get-RegistryProperty $h 'match'))
          $items.Add([pscustomobject]@{ Kind = 'hint_meta'; Key = $hid; Value = $meta })
          $items.Add([pscustomobject]@{ Kind = 'hint_title'; Key = $hid; Value = (Format-RegistryValue (Get-RegistryProperty $h 'title')) })
          foreach ($tok in (Get-RegistryArray $h 'tokens')) {
            $items.Add([pscustomobject]@{ Kind = 'hint_token'; Key = $hid; Value = (Format-RegistryValue $tok) })
          }
        }
      }
    }
  }
  return $res
}
