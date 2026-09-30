#!/usr/bin/env bash
# tests/golden/capture.sh -- capture the outputs that must stay byte-identical across the
# registry-unification work (invariants I1, I7, I8/I9, I10; DESIGN 9.2). Port of
# registry-unification/scratch/contract/golden.sh, which produced the frozen baseline
# G = $ARE_GOLD/before (never regenerated).
#
# Usage:
#   capture.sh [--no-ps] <label|/abs/dir> [<plugin-root>] [<registry-dir>]
#   capture.sh --synth-only <out-dir> [<plugin-root>] [<registry-dir>]
#     <label>        output dir $ARE_GOLD/<label> (e.g. after); an absolute path is used as is
#     <plugin-root>  plugins/android-reverse-engineering to exercise (default: this checkout)
#     <registry-dir> registry fed to both tools (default: <plugin-root>/skills/sdk-neutralizer/registry)
#     --no-ps        skip the PowerShell captures even when PowerShell is available
#     --synth-only   only the 9 synth48 scans, written directly under <out-dir>; used once
#                    (commit 0, product intact) to create G-synth = tests/golden/synth48.before
#                    (needs ARE_ALLOW_BASELINE=1 to overwrite it)
#
# Layout of a capture (compare.sh knows the baseline of each part):
#   scan/<app>/d<1-3>-<ads|trackers|all>/{stdout,stderr,exit,registry-*}  72 registry-scan runs
#   adwrapper/<app>/{stdout,stderr,exit}          detect-adwrapper.sh --registry <registry-dir>
#   adwrapper-noreg/<app>/{stdout,stderr,exit}    detect-adwrapper.sh without --registry
#                                                 (default resolution, as decode-apk.sh:643 runs it)
#   synth48/d<1-3>-<cat>/...                      9 registry-scan runs on the synth48 fixture,
#                                                 generated from the registry of $ARE_BASE_COMMIT
#   adwrapper-ps1[-noreg]/<app>.{norm,stderr}     detect-adwrapper.ps1 via -File (only with
#                                                 PowerShell); .norm = CR stripped, Windows input
#                                                 path mapped back to the Linux one; a non-zero
#                                                 exit leaves an <app>.EXIT_<rc> file
# The corpus is read-only: registry-scan always gets --output-dir inside the capture.
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
export LC_ALL=C

synth_only=0
use_ps=1
while [ $# -gt 0 ]; do
  case "$1" in
    --synth-only) synth_only=1; shift ;;
    --no-ps) use_ps=0; shift ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    -*) echo "capture.sh: unknown option $1" >&2; exit 1 ;;
    *) break ;;
  esac
done
LABEL="${1:?usage: capture.sh [--no-ps|--synth-only] <label|/abs/dir> [<plugin-root>] [<registry-dir>]}"
PLUG="${2:-$PL}"
NEU="$PLUG/skills/sdk-neutralizer"
REGD="${3:-$NEU/registry}"
[ -f "$NEU/scripts/registry-scan.py" ] || { echo "capture.sh: not a plugin root: $PLUG" >&2; exit 1; }
[ -d "$REGD" ] || { echo "capture.sh: registry not found: $REGD" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "capture.sh: python3 is required (registry-scan.py)" >&2; exit 1; }

case "$LABEL" in
  /*) OUT=$LABEL ;;
  */*|.|..|'') echo "capture.sh: a label is a plain name (or give an absolute path): $LABEL" >&2; exit 1 ;;
  *) OUT=$ARE_GOLD/$LABEL ;;
esac
OUT=${OUT%/}
[ -n "$OUT" ] && [ "$OUT" != / ] || { echo "capture.sh: refusing output dir '$LABEL'" >&2; exit 1; }
canon() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"; }
mkdir -p "$(dirname "$OUT")"
out_c=$(canon "$(dirname "$OUT")")/$(basename "$OUT")
gold_c=$(canon "$ARE_GOLD")
case "$out_c/" in
  "$gold_c/before/"*|"$gold_c/before-rerun/"*|"$gold_c/adwrapper-ps1-before/"*|"$gold_c/find-before/"*)
    echo "capture.sh: refusing to write into a frozen baseline: $OUT" >&2; exit 1 ;;
esac
if [ "$out_c" = "$(canon "$TESTS_DIR/golden")/synth48.before" ] && [ "${ARE_ALLOW_BASELINE:-0}" != 1 ]; then
  echo "capture.sh: refusing to overwrite G-synth ($OUT) without ARE_ALLOW_BASELINE=1" >&2; exit 1
fi
if [ -d "$OUT" ]; then # only ever wipe something that looks like a previous capture
  stray=$(find "$OUT" -mindepth 1 -maxdepth 1 ! -name scan ! -name adwrapper ! -name adwrapper-noreg \
            ! -name synth48 ! -name 'adwrapper-ps1*' ! -name 'd[123]-*' | head -n 1)
  [ -z "$stray" ] || { echo "capture.sh: $OUT exists and is not a capture ($stray); remove it first" >&2; exit 1; }
fi
rm -rf "$OUT"; mkdir -p "$OUT"

mktemp_dir work

# ---- synth48 -----------------------------------------------------------------------
capture_synth() { # capture_synth <dest-dir>
  local dest=$1 fix="$work/synth48" regsrc="$work/base-registry" depth cat o
  mkdir -p "$dest" "$regsrc"
  if ! git -C "$REPO" archive "$ARE_BASE_COMMIT" plugins/android-reverse-engineering/skills/sdk-neutralizer/registry 2>"$dest/FIXTURE_ERROR" |
       tar -x -C "$regsrc" 2>>"$dest/FIXTURE_ERROR"; then
    echo "capture.sh: cannot read the registry of $ARE_BASE_COMMIT from $REPO (see $dest/FIXTURE_ERROR)" >&2
    return 1
  fi
  bash "$TESTS_DIR/fixtures/make-synth48.sh" "$regsrc/plugins/android-reverse-engineering/skills/sdk-neutralizer/registry" "$fix" \
    2>>"$dest/FIXTURE_ERROR" || { echo "capture.sh: make-synth48.sh failed (see $dest/FIXTURE_ERROR)" >&2; return 1; }
  rm -f "$dest/FIXTURE_ERROR"
  for depth in 1 2 3; do
    for cat in ads trackers all; do
      o="$dest/d$depth-$cat"; mkdir -p "$o"
      python3 "$NEU/scripts/registry-scan.py" "$fix" --registry "$REGD" \
        --depth "$depth" --category "$cat" --output-dir "$o" >"$o/stdout" 2>"$o/stderr"
      echo "$?" >"$o/exit"
      sed -i "s#$o#<OUT>#g; s#$fix#<SYNTH>#g" "$o/stdout"
      sed -i "s#$fix#<SYNTH>#g" "$o/stderr"
    done
  done
}

if [ "$synth_only" = 1 ]; then
  capture_synth "$OUT" || exit 1
  echo "synth48 capture written to $OUT ($(find "$OUT" -type f | wc -l | tr -d ' ') files)"
  exit 0
fi

# ---- PowerShell: detect-adwrapper.ps1 (runs in the background, next to the sh part) ----
capture_ps() {
  local regw app D dw variant rc
  regw=$(wslpath -w "$REGD")
  for app in $CORPUS_APPS; do
    D="$ARE_CORPUS/$app-decoded"
    [ -d "$D" ] || continue
    dw=$(wslpath -w "$D")
    for variant in adwrapper-ps1 adwrapper-ps1-noreg; do
      mkdir -p "$OUT/$variant"
      if [ "$variant" = adwrapper-ps1 ]; then
        bash "$TESTS_DIR/parity/ps.sh" "$NEU/scripts/detect-adwrapper.ps1" "$dw" -Registry "$regw" \
          </dev/null >"$work/ps.out" 2>"$OUT/$variant/$app.stderr"
      else
        bash "$TESTS_DIR/parity/ps.sh" "$NEU/scripts/detect-adwrapper.ps1" "$dw" \
          </dev/null >"$work/ps.out" 2>"$OUT/$variant/$app.stderr"
      fi
      rc=$?
      [ "$rc" = 0 ] || : >"$OUT/$variant/$app.EXIT_$rc"
      tr -d '\r' <"$work/ps.out" | replace_literal "$dw" "$D" >"$OUT/$variant/$app.norm"
    done
  done
}
ps_pid=""
if [ "$use_ps" = 1 ] && have_ps && command -v wslpath >/dev/null 2>&1; then
  capture_ps & ps_pid=$!
else
  echo "capture.sh: PowerShell captures skipped (ARE_PS=$ARE_PS, --no-ps=$((1 - use_ps)))" >&2
fi

# ---- corpus: registry-scan + detect-adwrapper.sh ---------------------------------------
missing=""
for app in $CORPUS_APPS; do
  D="$ARE_CORPUS/$app-decoded"
  if [ ! -d "$D" ]; then missing="$missing $app"; continue; fi
  for depth in 1 2 3; do
    for cat in ads trackers all; do
      o="$OUT/scan/$app/d$depth-$cat"; mkdir -p "$o"
      python3 "$NEU/scripts/registry-scan.py" "$D" --registry "$REGD" \
        --depth "$depth" --category "$cat" --output-dir "$o" >"$o/stdout" 2>"$o/stderr"
      echo "$?" >"$o/exit"
      # make stdout path-independent (REGISTRY_TARGETS/MANIFEST carry $o)
      sed -i "s#$o#<OUT>#g" "$o/stdout"
    done
  done
  a="$OUT/adwrapper/$app"; mkdir -p "$a"
  bash "$NEU/scripts/detect-adwrapper.sh" "$D" --registry "$REGD" >"$a/stdout" 2>"$a/stderr"
  echo "$?" >"$a/exit"
  a="$OUT/adwrapper-noreg/$app"; mkdir -p "$a"
  bash "$NEU/scripts/detect-adwrapper.sh" "$D" >"$a/stdout" 2>"$a/stderr"
  echo "$?" >"$a/exit"
done
[ -z "$missing" ] || echo "capture.sh: WARN corpus apps missing under $ARE_CORPUS:$missing" >&2

capture_synth "$OUT/synth48" || echo "capture.sh: WARN synth48 not captured" >&2

[ -z "$ps_pid" ] || wait "$ps_pid"

# one-line fingerprint per file, for a quick eyeball
( cd "$OUT" && find . -type f | sort | xargs sha256sum ) >"$OUT.sha256"
echo "golden '$LABEL' written to $OUT ($(wc -l <"$OUT.sha256" | tr -d ' ') files)"
