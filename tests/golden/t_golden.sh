#!/usr/bin/env bash
# t_golden.sh -- invariant I1 (+ I7, I8/I9, I10): capture registry-scan (8 apps x depth
# 1-3 x ads/trackers/all + synth48) and detect-adwrapper (sh with and without --registry;
# ps1 too when PowerShell is available) with the product of this checkout, and require
# byte-identity with the frozen baseline G = $ARE_GOLD/before (+ G-synth, + the ps1
# baseline). Takes a few minutes; part of the `full` suite.
# Set ARE_GOLDEN_KEEP=1 to keep the capture dir for inspection.
# requires: cmd: command -v python3 >/dev/null
# requires: cmd: [ -d "$ARE_GOLD/before/scan" ]
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
have_corpus || skip "apktool corpus not found under $ARE_CORPUS (<app>-decoded for: $CORPUS_APPS)"
if [ "${ARE_GOLDEN_KEEP:-0}" = 1 ]; then
  out=$(mktemp -d "${TMPDIR:-/tmp}/are-golden.XXXXXX")
  echo "capture kept in $out/after"
else
  mktemp_dir out
fi
bash "$TESTS_DIR/golden/capture.sh" "$out/after" "$PL" || die "capture.sh failed"
bash "$TESTS_DIR/golden/compare.sh" "$ARE_GOLD/before" "$out/after"
