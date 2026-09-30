#!/usr/bin/env bash
# tests/parity/ps.sh <script.ps1> [args...] -- run a PowerShell 5.1 script from WSL the
# way the docs tell users to: from a Windows directory, with -File and a Windows path.
#   cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w X)" ...
# Arguments are passed verbatim: convert Linux paths with `wslpath -w` first.
# Stdout/stderr/exit code are the script's (the host appends one CRLF to the output).
# Exit 77 (SKIP) when PowerShell is not available (ARE_PS=none or not executable).
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
script="${1:?usage: ps.sh <script.ps1> [args...]}"; shift
have_ps || skip "PowerShell not available (ARE_PS=$ARE_PS)"
command -v wslpath >/dev/null 2>&1 || skip "wslpath not available"
win=$(wslpath -w "$script") || exit 1
cd /mnt/c || exit 1
exec "$ARE_PS" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$win" "$@"
