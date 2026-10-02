# find-ads.ps1 - thin wrapper of the SDK audit engine sdk-audit.ps1 (skills/sdk-neutralizer/
# scripts), which reads the SDK registry; PowerShell 5.1 twin of find-ads.sh (same options,
# same output). Run with -h for the options. SDK_AUDIT_ENGINE_PS1 overrides the engine path.
# The report goes to the pipeline as one string (`$r = & .\find-ads.ps1 <dir> --json` captures
# it in-process); exit 0 done, 1 error. No param() block: every token reaches the engine
# verbatim ($args), so --flags and -Flags both work.
$engine = $env:SDK_AUDIT_ENGINE_PS1
if ([string]::IsNullOrEmpty($engine)) { $engine = Join-Path $PSScriptRoot '..\..\sdk-neutralizer\scripts\sdk-audit.ps1' }
if (-not (Test-Path -LiteralPath $engine -PathType Leaf)) {
  [Console]::Error.Write("Error: sdk-audit engine not found at $engine (install the whole android-reverse-engineering plugin)`n")
  exit 1
}
. $engine
Invoke-SdkAudit -Tool 'find-ads' -Argv $args
exit $script:SdkAuditExit
