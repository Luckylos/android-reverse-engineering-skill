#!/usr/bin/env bash
# find-ads.sh — thin wrapper of the SDK audit engine sdk-audit.sh (skills/sdk-neutralizer/
# scripts), which reads the SDK registry. Run with -h for the options. SDK_AUDIT_ENGINE
# overrides the engine path.
ENGINE=${SDK_AUDIT_ENGINE:-$(cd "$(dirname "$0")" && pwd)/../../sdk-neutralizer/scripts/sdk-audit.sh}
if [ ! -f "$ENGINE" ]; then
  echo "Error: sdk-audit engine not found at $ENGINE (install the whole android-reverse-engineering plugin)" >&2
  exit 1
fi
exec "${BASH:-bash}" "$ENGINE" --tool find-ads "$@"
