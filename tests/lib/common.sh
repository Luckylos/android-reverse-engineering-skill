# shellcheck shell=bash
# tests/lib/common.sh -- shared helpers for the dev-only test harness (not shipped
# with the plugin). Sourced by tests/run.sh and by every test script, so each test
# can also be run on its own: `bash tests/unit/t_lint.sh`.
#
# Test protocol: exit 0 = PASS, exit 77 = SKIP (reason on the last output line),
# anything else = FAIL. A test declares its preconditions in its header with one or
# more `# requires: <token>...` lines (see tests/run.sh); run.sh prints
# SKIP(requires) when one is not met, so a suite whose feature lands in a later
# commit stays green until then.
#
# Environment (all optional; defaults are derived from the checkout location so the
# harness needs no local config when the repo lives next to the corpus):
#   ARE_WORKSPACE  directory that contains the repo checkout, test_apks/ and
#                  registry-unification/        (default: parent of the repo)
#   ARE_PLUGIN     plugin root under test        (default: <repo>/plugins/android-reverse-engineering)
#   ARE_CORPUS     apktool-decoded corpus: <app>-decoded dirs (default: $ARE_WORKSPACE/test_apks)
#   ARE_JADX       jadx corpus: <app>/ dirs      (default: $ARE_CORPUS/jadx)
#   ARE_GOLD       golden root; ARE_GOLD/before is the frozen baseline G
#                  (default: $ARE_WORKSPACE/registry-unification/scratch/contract/gold)
#   ARE_PRISTINE   fresh pristine decodes        (default: $ARE_WORKSPACE/registry-unification/pristine)
#   ARE_PS         Windows PowerShell 5.1 executable reachable from WSL; unset = autodetect,
#                  "none" (or 0) = disabled
#   BASH32         a bash 3.2 binary; unset = bash 3.2 checks are skipped
#   ARE_BASE_COMMIT  commit whose registry generates the synth48 fixture (default: 4c166fe)

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO=$(cd "$TESTS_DIR/.." && pwd)
PL=${ARE_PLUGIN:-$REPO/plugins/android-reverse-engineering}
PLUGIN=$PL
S=$PL/skills
NS=$S/sdk-neutralizer/scripts
REG=$S/sdk-neutralizer/registry

ARE_WORKSPACE=${ARE_WORKSPACE:-$(dirname "$REPO")}
ARE_CORPUS=${ARE_CORPUS:-$ARE_WORKSPACE/test_apks}
ARE_JADX=${ARE_JADX:-$ARE_CORPUS/jadx}
ARE_GOLD=${ARE_GOLD:-$ARE_WORKSPACE/registry-unification/scratch/contract/gold}
ARE_PRISTINE=${ARE_PRISTINE:-$ARE_WORKSPACE/registry-unification/pristine}
ARE_BASE_COMMIT=${ARE_BASE_COMMIT:-4c166fe}
BASH32=${BASH32:-}
if [ -z "${ARE_PS+x}" ]; then
  ARE_PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
  [ -x "$ARE_PS" ] || ARE_PS=none
fi
case "$ARE_PS" in ''|0) ARE_PS=none ;; esac

# The 8 apps of the apktool golden corpus (G = $ARE_GOLD/before).
CORPUS_APPS="af1945 alto badpiggies blockcraft bulldozer heartstar subway ttom2"

SKIP_RC=77
export TESTS_DIR REPO PL PLUGIN S NS REG ARE_WORKSPACE ARE_CORPUS ARE_JADX ARE_GOLD \
  ARE_PRISTINE ARE_BASE_COMMIT BASH32 ARE_PS

# --- result helpers ---------------------------------------------------------------
skip() { echo "SKIP: $*"; exit "$SKIP_RC"; }
die()  { echo "FAIL: $*"; exit 1; }

# Assertions record failures in _T_FAILS and keep going; finish with t_done.
_T_FAILS=0
_T_CHECKS=0
fail_check() { _T_FAILS=$((_T_FAILS + 1)); echo "  not ok: $*"; }
pass_check() { [ -n "${T_VERBOSE:-}" ] && echo "  ok: $*"; return 0; }
assert_eq() { # assert_eq <expected> <actual> <message>
  _T_CHECKS=$((_T_CHECKS + 1))
  if [ "$1" = "$2" ]; then pass_check "$3"; else
    fail_check "$3"; echo "    expected: [$1]"; echo "    actual:   [$2]"; fi
}
assert_true() { # assert_true <message> <command...>
  _t_msg=$1; shift; _T_CHECKS=$((_T_CHECKS + 1))
  if "$@"; then pass_check "$_t_msg"; else fail_check "$_t_msg"; fi
}
assert_false() { # assert_false <message> <command...>
  _t_msg=$1; shift; _T_CHECKS=$((_T_CHECKS + 1))
  if "$@"; then fail_check "$_t_msg"; else pass_check "$_t_msg"; fi
}
assert_files_eq() { # assert_files_eq <expected-file> <actual-file> <message>
  _T_CHECKS=$((_T_CHECKS + 1))
  if cmp -s "$1" "$2"; then pass_check "$3"; else
    fail_check "$3"; diff -u "$1" "$2" 2>&1 | head -30 | sed 's/^/    /'; fi
}
t_done() { # print the summary line and exit with the protocol code
  if [ "$_T_FAILS" -eq 0 ]; then echo "ok: $_T_CHECKS check(s)"; exit 0; fi
  echo "FAIL: $_T_FAILS of $_T_CHECKS check(s) failed"; exit 1
}

# --- environment helpers ------------------------------------------------------------
# mktemp_dir <var>: create a private temp dir, store its path in <var>, remove it at
# exit. Call it directly (not inside $(...): the EXIT trap would fire in the subshell).
# The list is newline-separated and never re-parsed by the shell, so a TMPDIR with
# spaces or glob characters (e.g. /mnt/c/Users/First Last/...) is removed exactly.
_T_TMPS=""
_t_cleanup() {
  printf '%s\n' "$_T_TMPS" | while IFS= read -r _c; do
    [ -n "$_c" ] && rm -rf -- "$_c"
  done
  return 0
}
mktemp_dir() {
  _d=$(mktemp -d "${TMPDIR:-/tmp}/are-tests.XXXXXX") || die "mktemp failed"
  _T_TMPS="$_T_TMPS
$_d"
  trap _t_cleanup EXIT
  eval "$1=\$_d"
}

# run_bash <script> [args...]: run a product bash script with $BASH32 when set.
run_bash() { "${BASH32:-bash}" "$@"; }

# with_shim <shim-name> <command...>: run a command with tests/shims/<name> first on PATH
# (nojq, jq15, nosudo, awk-gawk-posix, awk-mawk, awk-busybox). The jq shims also get
# HOME=$NO_HOME: the product scripts prepend ~/.local/bin to PATH when it is missing,
# and a real ~/.local/bin/jq (from `install-dep.sh jq`) would then win over the shim.
NO_HOME=$TESTS_DIR/shims/no-home   # never created
with_shim() {
  _s=$1; shift
  case "$_s" in
    nojq|jq15) HOME=$NO_HOME PATH="$TESTS_DIR/shims/$_s:$PATH" "$@" ;;
    *)         PATH="$TESTS_DIR/shims/$_s:$PATH" "$@" ;;
  esac
}

# awk_shims: the awk shims whose underlying binary exists on this machine.
awk_shims() {
  command -v gawk >/dev/null 2>&1 && echo awk-gawk-posix
  command -v mawk >/dev/null 2>&1 && echo awk-mawk
  command -v busybox >/dev/null 2>&1 && busybox awk 'BEGIN{}' >/dev/null 2>&1 && echo awk-busybox
  return 0
}

have_jq16() { # jq present and >= 1.6 (same probe as registry-query, DESIGN 4.3)
  [ "$(jq -nr '[limit(1;1,2)] | IN(.[]; 1) | tostring' 2>/dev/null)" = true ]
}
have_ps() { [ "$ARE_PS" != none ] && [ -x "$ARE_PS" ]; }
have_corpus() { # have_corpus: every app of CORPUS_APPS has its <app>-decoded dir
  for _a in $CORPUS_APPS; do [ -d "$ARE_CORPUS/$_a-decoded" ] || return 1; done
}

# normalize [<input-prefix>]: stdin -> stdout, for sh/ps1 comparisons (DESIGN I21/I22):
# strip a CR before each LF, replace the literal input prefix with <IN>, then '\' -> '/'.
# (Strings reach awk through ENVIRON: `awk -v` would interpret the backslashes.)
normalize() {
  _ARE_PFX="${1:-}" LC_ALL=C awk '
    BEGIN { pfx = ENVIRON["_ARE_PFX"] }
    { sub(/\r$/, "")
      if (pfx != "") {
        out = ""; s = $0
        while ((i = index(s, pfx)) > 0) { out = out substr(s, 1, i - 1) "<IN>"; s = substr(s, i + length(pfx)) }
        $0 = out s
      }
      gsub(/\\/, "/"); print }'
}

# replace_literal <from> <to>: stdin -> stdout, literal (non-regex) substring replacement.
replace_literal() {
  _ARE_FROM="$1" _ARE_TO="$2" LC_ALL=C awk '
    BEGIN { from = ENVIRON["_ARE_FROM"]; to = ENVIRON["_ARE_TO"] }
    { out = ""; s = $0
      if (from != "") while ((i = index(s, from)) > 0) { out = out substr(s, 1, i - 1) to; s = substr(s, i + length(from)) }
      print out s }'
}

# header_block <file>: print the leading comment block of a script: every line from
# line 1 up to (not including) the first line that does not start with `#`. Test
# directives (`# requires:`, `# awk-matrix`) are read only from here; t_runner fails
# when one appears further down, where it would be silently ignored.
header_block() {
  LC_ALL=C awk '!/^#/ { exit } { print }' "$1"
}

# directives_outside_header <file>...: print `file:line: text` for every `# requires:` /
# `# awk-matrix` line that is NOT in the leading comment block (so it would be ignored).
directives_outside_header() {
  LC_ALL=C awk '
    FNR == 1 { inhdr = 1 }
    inhdr && !/^#/ { inhdr = 0 }
    !inhdr && /^#[[:space:]]*(requires:|awk-matrix)/ { print FILENAME ":" FNR ": " $0 }
  ' "$@"
}

# requires_unmet <test-file>: print the first unmet `# requires:` token of a test (see
# tests/run.sh for the syntax), nothing when all are met. Only the leading comment block
# is read (header_block). `cmd:` tokens are evaluated in a subshell with this file loaded.
requires_unmet() {
  header_block "$1" | sed -n 's/^# requires:[[:space:]]*//p' | while IFS= read -r _line; do
    while [ -n "$_line" ]; do
      case "$_line" in
        cmd:*)
          _c=${_line#cmd:}
          if ! ( eval "$_c" ) >/dev/null 2>&1; then echo "cmd:$_c"; exit 0; fi
          _line="" ;;
        *)
          _tok=${_line%%[[:space:]]*}
          if [ "$_tok" = "$_line" ]; then _line=""; else
            _line=${_line#"$_tok"}; _line=${_line#"${_line%%[![:space:]]*}"}; fi
          case "$_tok" in
            NS/*)    _p=$NS/${_tok#NS/} ;;
            S/*)     _p=$S/${_tok#S/} ;;
            PL/*)    _p=$PL/${_tok#PL/} ;;
            REG/*)   _p=$REG/${_tok#REG/} ;;
            TESTS/*) _p=$TESTS_DIR/${_tok#TESTS/} ;;
            *)       _p=$REPO/$_tok ;;
          esac
          [ -e "$_p" ] || { echo "$_tok"; exit 0; } ;;
      esac
    done
  done
}

# A test run directly (`bash tests/unit/t_x.sh`) honours its own `# requires:` lines too.
case "$(basename "$0")" in
  t_*.sh)
    _unmet=$(requires_unmet "$0")
    if [ -n "$_unmet" ]; then echo "SKIP(requires): missing $_unmet"; exit "$SKIP_RC"; fi ;;
esac
