#!/usr/bin/env bash
# bash32.sh -- suite `bash32` (DESIGN 9.1 I18, 9.2 `full`): the product scripts that
# promise macOS stock bash 3.2 compatibility really run on bash 3.2.
#   1. `$BASH32 -n` (syntax) on every such script: install-dep.sh, check-neutralize-deps.sh,
#      decode-apk.sh, rebuild-apk.sh, detect-adwrapper.sh, registry-query.sh, sdk-audit.sh,
#      find-trackers.sh, find-ads.sh;
#   2. every unit test that runs product scripts through $BASH32 (the tests whose source
#      uses `run_bash` or `$BASH32`) is run again with BASH32 exported, once each; a
#      SKIP of one of them is a failure here (they all exist from commit 8 on);
#   3. corpus/find-golden.sh with BASH32 (find-*.sh --tsv on the pristine decodes ==
#      tests/golden/find), when the pristine corpus is there (else a note).
# The bash 3.2 binary: $BASH32, else $ARE_WORKSPACE/registry-unification/scratch/bash32/bash32
# (the build the DESIGN names); neither present = SKIP. The regular suites keep running
# with the default bash, so both bash versions are covered by `tests/run.sh full`.
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
export LC_ALL=C

if [ -z "$BASH32" ]; then
  _b=$ARE_WORKSPACE/registry-unification/scratch/bash32/bash32
  [ -x "$_b" ] && BASH32=$_b
fi
[ -n "$BASH32" ] || skip "no bash 3.2 binary (set BASH32)"
[ -x "$BASH32" ] || command -v "$BASH32" >/dev/null 2>&1 || skip "BASH32=$BASH32 is not executable"
ver=$("$BASH32" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"' 2>/dev/null)
assert_eq 3.2 "$ver" "BASH32 is bash 3.2 ($BASH32)"
[ "$ver" = 3.2 ] || t_done
export BASH32
echo "bash 3.2: $BASH32 ($("$BASH32" --version | head -n 1))"

# 1. syntax
for s in "$S/android-reverse-engineering/scripts/install-dep.sh" \
         "$NS/check-neutralize-deps.sh" "$NS/decode-apk.sh" "$NS/rebuild-apk.sh" \
         "$NS/detect-adwrapper.sh" "$NS/registry-query.sh" "$NS/sdk-audit.sh" \
         "$S/tracker-analysis/scripts/find-trackers.sh" "$S/ad-analysis/scripts/find-ads.sh"; do
  if [ -f "$s" ]; then
    err=$("$BASH32" -n "$s" 2>&1)
    assert_eq "" "$err" "bash 3.2 -n ${s#$PL/}"
  else
    fail_check "missing script ${s#$PL/}"
  fi
done

# 2. unit tests that use $BASH32
mktemp_dir tmp
# names only (no directories): the checkout path may contain spaces
tests=$(cd "$TESTS_DIR/unit" && grep -l -e 'run_bash' -e 'BASH32' t_*.sh | grep -vx 't_common\.sh' | sort)
[ -n "$tests" ] || die "no unit test uses BASH32"
for f in $tests; do
  t=$TESTS_DIR/unit/$f
  n=${f%.sh}
  _T_CHECKS=$((_T_CHECKS + 1))
  bash "$t" >"$tmp/$n.out" 2>&1; rc=$?
  case "$rc" in
    0) pass_check "$n under bash 3.2"; echo "  $n: $(tail -n 1 "$tmp/$n.out")" ;;
    77) fail_check "$n under bash 3.2: skipped ($(tail -n 1 "$tmp/$n.out"))" ;;
    *) fail_check "$n under bash 3.2: rc $rc"; tail -n 25 "$tmp/$n.out" | sed 's/^/    /' ;;
  esac
done

# 3. corpus goldens of the audit
fg=$TESTS_DIR/corpus/find-golden.sh
if [ -f "$fg" ]; then
  bash "$fg" >"$tmp/find-golden.out" 2>&1; rc=$?
  case "$rc" in
    0) assert_eq 0 0 "find-golden under bash 3.2"; echo "  find-golden: $(tail -n 1 "$tmp/find-golden.out")" ;;
    77) echo "  note: find-golden skipped under bash 3.2 ($(tail -n 1 "$tmp/find-golden.out"))" ;;
    *) fail_check "find-golden under bash 3.2: rc $rc"; tail -n 25 "$tmp/find-golden.out" | sed 's/^/    /' ;;
  esac
fi

t_done
