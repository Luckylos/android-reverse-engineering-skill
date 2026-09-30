#!/usr/bin/env bash
# t_lint.sh -- self-test of tests/lint/lint-registry.sh (rules L1-L4): the real
# registry is clean, and one mutated copy per rule is rejected with that rule id.
# requires: cmd: have_jq16
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

LINT=$TESTS_DIR/lint/lint-registry.sh
mktemp_dir tmp

out=$(bash "$LINT" "$REG" 2>&1); rc=$?
[ "$rc" = 77 ] && skip "$out"
assert_eq 0 "$rc" "real registry passes lint"
[ "$rc" = 0 ] || printf '%s\n' "$out" | head -20

base=$REG/mixpanel.json
[ -f "$base" ] || die "fixture source missing: $base"

# case <name> <expected-rule> <file-name> : content on stdin
case_n=0
lint_case() {
  name=$1 rule=$2 fname=$3
  case_n=$((case_n + 1))
  d=$tmp/case$case_n; mkdir -p "$d"
  cp "$REG/_schema.json" "$d/"
  cat >"$d/$fname"
  out=$(bash "$LINT" "$d" 2>&1); rc=$?
  assert_eq 1 "$rc" "$name: lint exits 1"
  _T_CHECKS=$((_T_CHECKS + 1))
  if printf '%s\n' "$out" | grep -q "^$rule ERROR $fname: "; then pass_check "$name: $rule reported"; else
    fail_check "$name: expected a '$rule ERROR $fname' finding"; printf '%s\n' "$out" | sed 's/^/    /' | head -10; fi
}
mut() { jq "$1" "$base"; } # pretty-printed, LF, final newline

{ printf '\357\273\277'; cat "$base"; } >"$tmp/in"; lint_case "BOM" L1 mixpanel.json <"$tmp/in"
sed 's/$/\r/' "$base" >"$tmp/in"; lint_case "CRLF" L1 mixpanel.json <"$tmp/in"
printf '%s' "$(cat "$base")" >"$tmp/in"; lint_case "no final newline" L1 mixpanel.json <"$tmp/in"
{ cat "$base"; cat "$base"; } >"$tmp/in"; lint_case "two JSON documents" L1 mixpanel.json <"$tmp/in"
echo '[1, 2]' >"$tmp/in"; lint_case "root not an object" L1 mixpanel.json <"$tmp/in"
: >"$tmp/in"; lint_case "empty file" L1 mixpanel.json <"$tmp/in"
printf '{ "sdk_id": "mixpanel", \n' >"$tmp/in"; lint_case "truncated JSON" L1 mixpanel.json <"$tmp/in"
printf '{"sdk_id":"mixpanel","display_name":"Mix\377panel"}\n' >"$tmp/in"; lint_case "invalid UTF-8" L1 mixpanel.json <"$tmp/in"

mut '.' >"$tmp/in"; lint_case "sdk_id differs from file name" L2 other.json <"$tmp/in"
mut '.sdk_id = "MixPanel"' >"$tmp/in"; lint_case "sdk_id not lowercase" L2 mixpanel.json <"$tmp/in"
mut 'del(.sdk_id)' >"$tmp/in"; lint_case "sdk_id missing" L2 mixpanel.json <"$tmp/in"
d=$tmp/dup; mkdir -p "$d"; cp "$REG/_schema.json" "$d/"; cp "$base" "$d/mixpanel.json"
mut '.' >"$d/consent-umptcf.json"   # consent-umptcf.json may only hold google-ump-consent
out=$(bash "$LINT" "$d" 2>&1)
assert_true "consent-umptcf.json exception is only for google-ump-consent" \
  sh -c 'printf "%s\n" "$1" | grep -q "^L2 ERROR consent-umptcf.json: "' _ "$out"

mut '.display_name = "Mix:panel"' >"$tmp/in"; lint_case "display_name with colon" L3 mixpanel.json <"$tmp/in"
mut '.display_name = "Mix|panel"' >"$tmp/in"; lint_case "display_name with pipe" L3 mixpanel.json <"$tmp/in"
mut '.display_name = "Mix\npanel"' >"$tmp/in"; lint_case "display_name with newline" L3 mixpanel.json <"$tmp/in"
mut '.display_name = 42' >"$tmp/in"; lint_case "display_name not a string" L3 mixpanel.json <"$tmp/in"
mut '.vendor = null' >"$tmp/in"; lint_case "vendor not a string" L3 mixpanel.json <"$tmp/in"
mut '.category = "push"' >"$tmp/in"; lint_case "category outside the enum" L3 mixpanel.json <"$tmp/in"

mut '.targets = null' >"$tmp/in"; lint_case "targets null" L4 mixpanel.json <"$tmp/in"
mut 'del(.targets) | .manifest_components = [{"type":"service","class":"com.mixpanel.android.X","action":"disable"}]' >"$tmp/in"; lint_case "detection-only entry with manifest_components" L4 mixpanel.json <"$tmp/in"
mut 'del(.targets) | del(.manifest_components) | .protected_patterns = [{"pattern":"*.x()*","reason":"r"}]' >"$tmp/in"; lint_case "detection-only entry with protected_patterns" L4 mixpanel.json <"$tmp/in"

t_done
