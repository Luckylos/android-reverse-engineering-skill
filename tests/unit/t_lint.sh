#!/usr/bin/env bash
# t_lint.sh -- self-test of tests/lint/lint-registry.sh (rules L1-L15): the real
# registry is clean (errors; L11 WARN / L14 INFO allowed), one mutated copy per rule
# (and per check of the rule) is reported with that rule id, and the detection-only
# entries planned by DESIGN 3.3 (segment, flurry) lint clean, schema included.
# requires: cmd: have_jq16
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

LINT=$TESTS_DIR/lint/lint-registry.sh
mktemp_dir tmp

out=$(bash "$LINT" "$REG" 2>&1); rc=$?
[ "$rc" = 77 ] && skip "$out"
assert_eq 0 "$rc" "real registry passes lint"
[ "$rc" = 0 ] || printf '%s\n' "$out" | head -20
real_out=$out
summary=$(printf '%s\n' "$real_out" | tail -n 1)
_T_CHECKS=$((_T_CHECKS + 1))
case "$summary" in
  *" 0 error(s),"*"[rules L1-L15, schema: "*) pass_check "real registry: every rule ran (L1-L15, none skipped), 0 errors" ;;
  *) fail_check "real registry summary: expected 0 errors and [rules L1-L15, ...]: $summary" ;;
esac
assert_eq "" "$(printf '%s\n' "$real_out" | grep '^L15 ')" "real registry: no L15 finding (allowlist exact)"
assert_true "real registry: L14 reports com/mopub (no owning entry)" \
  sh -c 'printf "%s\n" "$1" | grep -qx "L14 INFO detect-adwrapper.sh: NETWORK_ROOTS com/mopub (mopub): no owning registry entry"' _ "$real_out"

base=$REG/mixpanel.json
[ -f "$base" ] || die "fixture source missing: $base"

# case <name> <expected-rule> <file-name> [<message-substring>] : content on stdin
case_n=0
lint_case() {
  name=$1 rule=$2 fname=$3 msg=${4:-}
  case_n=$((case_n + 1))
  d=$tmp/case$case_n; mkdir -p "$d"
  cp "$REG/_schema.json" "$d/"
  cat >"$d/$fname"
  dir_case "$name" "$rule" ERROR "$fname" "$msg" "$d"
}
# the SCHEMA cases need the jsonschema pass; the L-rule cases skip it (speed)
LINT_OPTS=--no-schema
# dir_case <name> <rule> <ERROR|WARN|INFO> <file> <message-substring> <dir>: lint <dir>
# and expect a `<rule> <level> <file>: ...<message>` line; exit 1 for ERROR, else 0
dir_case() {
  _n=$1 _r=$2 _l=$3 _f=$4 _m=$5 _d=$6
  case "$_r" in SCHEMA) _o="" ;; *) _o=$LINT_OPTS ;; esac
  out=$(bash "$LINT" $_o "$_d" 2>&1); rc=$?
  if [ "$_l" = ERROR ]; then assert_eq 1 "$rc" "$_n: lint exits 1"; else assert_eq 0 "$rc" "$_n: lint exits 0"; fi
  _T_CHECKS=$((_T_CHECKS + 1))
  if printf '%s\n' "$out" | grep "^$_r $_l $_f: " | grep -qF -e "$_m"; then pass_check "$_n: $_r reported"; else
    fail_check "$_n: expected a '$_r $_l $_f: ...$_m' finding"; printf '%s\n' "$out" | sed 's/^/    /' | head -10; fi
}
# clean_dir <name> <dir>: lint <dir> and expect exit 0 without any ERROR line
clean_dir() {
  out=$(bash "$LINT" $LINT_OPTS "$2" 2>&1); rc=$?
  assert_eq 0 "$rc" "$1: lint exits 0"
  [ "$rc" = 0 ] || printf '%s\n' "$out" | sed 's/^/    /' | head -10
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
out=$(bash "$LINT" $LINT_OPTS "$d" 2>&1)
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

# targets is optional (DESIGN 2.1, commit 1): a detection-only entry is clean, schema included
d=$tmp/detonly; mkdir -p "$d"; cp "$REG/_schema.json" "$d/"
mut 'del(.targets) | del(.manifest_components) | del(.protected_patterns)' >"$d/mixpanel.json"
out=$(bash "$LINT" "$d" 2>&1); rc=$?
assert_eq 0 "$rc" "detection-only entry (no targets) passes lint"
[ "$rc" = 0 ] || printf '%s\n' "$out" | sed 's/^/    /' | head -10

# the schema itself (only when python jsonschema is available): if/then and display_name
# pattern; the substring is the failing schema path printed by lint (`[<schema path>]`),
# which makes sure it is the new constraint that fires (with the old schema a missing
# `targets` was reported at `[required]`) and, unlike the message text, does not depend on
# the jsonschema version (3.x: `[if/then/not]` "... is not allowed for ..."; 4.x:
# `[then/not]` "... should not be valid under ...", cut before that text by the 200-char limit)
if python3 -c 'import jsonschema' >/dev/null 2>&1; then
  mut 'del(.targets) | del(.protected_patterns) | .manifest_components = [{"type":"service","class":"com.mixpanel.android.X","action":"disable"}]' >"$tmp/in"
  lint_case "schema if/then: detection-only entry with manifest_components" SCHEMA mixpanel.json "then/not]:" <"$tmp/in"
  mut 'del(.targets) | del(.manifest_components) | .protected_patterns = [{"pattern":"*.x()*","reason":"r"}]' >"$tmp/in"
  lint_case "schema if/then: detection-only entry with protected_patterns" SCHEMA mixpanel.json "then/not]:" <"$tmp/in"
  mut '.display_name = "Mix:panel"' >"$tmp/in"; lint_case "schema pattern: display_name with colon" SCHEMA mixpanel.json "[properties/display_name/pattern]:" <"$tmp/in"
  mut '.display_name = "Mix\tpanel"' >"$tmp/in"; lint_case "schema pattern: display_name with tab" SCHEMA mixpanel.json "[properties/display_name/pattern]:" <"$tmp/in"
  mut '.targets = null' >"$tmp/in"; lint_case "schema: targets null" SCHEMA mixpanel.json "[properties/targets/type]:" <"$tmp/in"
  mut '.detection = {"domains": ["mixpanel.com"], "id_patterns": []}' >"$tmp/in"
  lint_case "schema: unknown detection key" SCHEMA mixpanel.json "additionalProperties]:" <"$tmp/in"
  mut '.detection = {"marker_classes": ["com.mixpanel.android.mpmetrics.MixpanelAPI$People"]}' >"$tmp/in"
  lint_case "schema: marker class with \$" SCHEMA mixpanel.json "[properties/detection/" <"$tmp/in"
  mut '.detection = {"apis": [{"class": "com.mixpanel.android.mpmetrics.MixpanelAPI", "methods": ["track"], "role": "tracking"}]}' >"$tmp/in"
  lint_case "schema: api role outside the enum" SCHEMA mixpanel.json "role/enum]:" <"$tmp/in"
fi
# ---- L5: keys allowed by _schema.json ------------------------------------------------
mut '.foo = 1' >"$tmp/in"; lint_case "unknown top-level key" L5 mixpanel.json '"foo"' <"$tmp/in"
mut '.detection = []' >"$tmp/in"; lint_case "detection not an object" L5 mixpanel.json "detection must be an object" <"$tmp/in"
mut '.detection = {"domains": ["mixpanel.com"], "id_patterns": []}' >"$tmp/in"; lint_case "unknown detection key" L5 mixpanel.json '"id_patterns"' <"$tmp/in"
mut '.detection = {"apis": [{"class": "com.mixpanel.android.mpmetrics.MixpanelAPI", "methods": ["track"], "role": "event", "format": "x"}]}' >"$tmp/in"
lint_case "unknown detection.apis item key" L5 mixpanel.json 'detection.apis[0] key(s) not in the schema: "format"' <"$tmp/in"
mut '.detection = {"id_prefixes": [{"prefix": "mp-tok-", "label": "mp", "regex": "x"}]}' >"$tmp/in"
lint_case "unknown detection.id_prefixes item key" L5 mixpanel.json 'detection.id_prefixes[0] key(s) not in the schema: "regex"' <"$tmp/in"

# ---- L6: case-colliding keys, any depth, `_` files too ----------------------------------
mut '.obfuscation = {"public_api": "readable", "Public_api": "mixed"}' >"$tmp/in"
lint_case "case-colliding keys (nested)" L6 mixpanel.json 'at .obfuscation: "public_api", "Public_api"' <"$tmp/in"
mut '.Vendor = "x"' >"$tmp/in"; lint_case "case-colliding keys (top level)" L6 mixpanel.json 'at (root)' <"$tmp/in"
d=$tmp/l6shared; mkdir -p "$d"; cp "$REG/_schema.json" "$base" "$d/"
printf '{"hints": [{"id": "a", "ID": "b"}]}\n' >"$d/_x.json"
dir_case "case-colliding keys in a _ file" L6 ERROR _x.json 'at .hints[0]: "id", "ID"' "$d"

# ---- L7: syntax ------------------------------------------------------------------------
mut '.packages += ["Com.mixpanel"]' >"$tmp/in"; lint_case "bad package in packages" L7 mixpanel.json 'packages: "Com.mixpanel" is not a valid package name' <"$tmp/in"
mut '.detection = {"extra_packages": ["com.mixpanel-x"]}' >"$tmp/in"; lint_case "bad package in extra_packages" L7 mixpanel.json 'detection.extra_packages: "com.mixpanel-x"' <"$tmp/in"
mut '.detection = {"namespace_roots": ["com.mixpanel."]}' >"$tmp/in"; lint_case "bad package in namespace_roots" L7 mixpanel.json 'detection.namespace_roots: "com.mixpanel."' <"$tmp/in"
mut '.detection = {"adapter_packages": [42]}' >"$tmp/in"; lint_case "non-string in adapter_packages" L7 mixpanel.json 'detection.adapter_packages: item 42 is not a string' <"$tmp/in"
mut '.detection = {"exclude_packages": "com.mixpanel.android.x"}' >"$tmp/in"; lint_case "exclude_packages not an array" L7 mixpanel.json 'detection.exclude_packages must be an array' <"$tmp/in"
mut '.detection = {"marker_classes": ["com.mixpanel.android.mpmetrics.MixpanelAPI$People"]}' >"$tmp/in"; lint_case "marker with \$" L7 mixpanel.json "must be a top-level class (no '\$')" <"$tmp/in"
mut '.detection = {"marker_classes": ["MixpanelAPI"]}' >"$tmp/in"; lint_case "marker not qualified" L7 mixpanel.json 'detection.marker_classes: "MixpanelAPI" is not a valid' <"$tmp/in"
mut '.detection = {"domains": ["Mixpanel.com"]}' >"$tmp/in"; lint_case "domain with uppercase" L7 mixpanel.json 'detection.domains: "Mixpanel.com"' <"$tmp/in"
mut '.detection = {"domains": ["localhost"]}' >"$tmp/in"; lint_case "domain without a dot" L7 mixpanel.json 'detection.domains: "localhost"' <"$tmp/in"
mut '.detection = {"domains": ["mixpanel.com", "mixpanel.com"]}' >"$tmp/in"; lint_case "duplicate domain" L7 mixpanel.json 'detection.domains: duplicate item(s) "mixpanel.com"' <"$tmp/in"
mut '.detection = {"manifest_names": ["com.mixpanel token"]}' >"$tmp/in"; lint_case "manifest_name with a space" L7 mixpanel.json 'detection.manifest_names: "com.mixpanel token"' <"$tmp/in"
api() { mut ".detection = {\"apis\": [$1]}"; }
api '{"class": "MixpanelAPI", "methods": ["track"], "role": "event"}' >"$tmp/in"; lint_case "api class not qualified" L7 mixpanel.json 'detection.apis[0].class "MixpanelAPI"' <"$tmp/in"
api '{"class": "com.mixpanel.android.mpmetrics.MixpanelAPI", "methods": ["track()"], "role": "event"}' >"$tmp/in"; lint_case "api method with parens" L7 mixpanel.json 'detection.apis[0].methods: "track()"' <"$tmp/in"
api '{"class": "com.mixpanel.android.mpmetrics.MixpanelAPI", "methods": [], "role": "event"}' >"$tmp/in"; lint_case "api without methods" L7 mixpanel.json 'detection.apis[0].methods must be a non-empty array' <"$tmp/in"
api '{"class": "com.mixpanel.android.mpmetrics.MixpanelAPI", "methods": ["track"], "role": "tracking"}' >"$tmp/in"; lint_case "api role outside the enum" L7 mixpanel.json 'detection.apis[0].role "tracking"' <"$tmp/in"
api '{"class": "com.mixpanel.android.mpmetrics.MixpanelAPI", "methods": ["track"]}' >"$tmp/in"; lint_case "api without role" L7 mixpanel.json 'detection.apis[0].role null' <"$tmp/in"
api '"com.mixpanel.android.mpmetrics.MixpanelAPI#track"' >"$tmp/in"; lint_case "api not an object" L7 mixpanel.json 'detection.apis[0] must be an object' <"$tmp/in"
mut '.detection = {"id_prefixes": [{"prefix": "mp-", "label": "mp"}]}' >"$tmp/in"; lint_case "id prefix too short" L7 mixpanel.json 'detection.id_prefixes[0].prefix must be a string of at least 4' <"$tmp/in"
mut '.detection = {"id_prefixes": [{"prefix": "mp-tok-", "label": "MP"}]}' >"$tmp/in"; lint_case "id prefix label uppercase" L7 mixpanel.json 'detection.id_prefixes[0].label "MP"' <"$tmp/in"

# ---- L8: extra disjoint from packages; exclude strictly under an own root ---------------
mut '.detection = {"extra_packages": ["com.mixpanel.android"]}' >"$tmp/in"; lint_case "extra_package already in packages" L8 mixpanel.json '"com.mixpanel.android" is already in packages' <"$tmp/in"
mut '.detection = {"exclude_packages": ["com.other.x"]}' >"$tmp/in"; lint_case "exclude outside the roots" L8 mixpanel.json '"com.other.x" is not strictly under a root' <"$tmp/in"
mut '.detection = {"exclude_packages": ["com.mixpanel.android"]}' >"$tmp/in"; lint_case "exclude equal to the root" L8 mixpanel.json '"com.mixpanel.android" is not strictly under a root' <"$tmp/in"
d=$tmp/l8ok; mkdir -p "$d"; cp "$REG/_schema.json" "$d/"
mut '.detection = {"extra_packages": ["com.mixpanel.legacy"], "exclude_packages": ["com.mixpanel.android.util", "com.mixpanel.legacy.x"]}' >"$d/mixpanel.json"
clean_dir "exclude under packages or under extra_packages" "$d"

# ---- L9: packages / sdk_id / in_house_wrapper once, top level, awk-readable ---------------
jq -c . "$base" >"$tmp/in"; lint_case "whole entry on one line" L9 mixpanel.json '`"packages": [` must end its line' <"$tmp/in"
mut '.packages += ["com.mixpanel.extra"]' | awk '/"packages": \[/ { print "  \"packages\": [\"com.mixpanel.android\","; getline; next } { print }' >"$tmp/in"
lint_case "packages item on the bracket line" L9 mixpanel.json 'must end its line' <"$tmp/in"
mut '.packages = ["com.mixpanel.android", "com.mixpanel.b"]' | awk '/"com.mixpanel.android",/ { printf "%s", $0; getline; sub(/^ */, " "); print; next } { print }' >"$tmp/in"
lint_case "two packages items on one line" L9 mixpanel.json 'a packages item must be a plain string alone on its line' <"$tmp/in"
sed 's/"com.mixpanel.android"/"com.mixpanel.\\u0061ndroid"/' "$base" >"$tmp/in"
lint_case "escape in a packages item" L9 mixpanel.json 'line 10: a packages item must be a plain string alone on its line' <"$tmp/in"
mut '.obfuscation = {"packages": ["x"]}' >"$tmp/in"; lint_case "packages key below the top level" L9 mixpanel.json 'key "packages" must appear only at the top level (found at .obfuscation.packages)' <"$tmp/in"
mut '.detection = {"note": "x"} | .detection.sdk_id = "other"' >"$tmp/in"; lint_case "sdk_id key below the top level" L9 mixpanel.json '"sdk_id": appears 2 times' <"$tmp/in"
mut '.' | awk '/"sdk_id":/ { print "  \"sdk_id\":"; sub(/^ *"sdk_id": */, "    "); print; next } { print }' >"$tmp/in"
lint_case "sdk_id value on the next line" L9 mixpanel.json 'the awk fallback reads sdk_id "nothing"' <"$tmp/in"
mut '.in_house_wrapper = true' | awk '/"in_house_wrapper": true/ { print "  \"in_house_wrapper\":"; print "    true"; next } { print }' >"$tmp/in"
lint_case "in_house_wrapper value on the next line" L9 mixpanel.json 'the awk fallback reads in_house_wrapper=false' <"$tmp/in"

# ---- L10: in-house packages disjoint --------------------------------------------------------
d=$tmp/l10; mkdir -p "$d"; cp "$REG/_schema.json" "$base" "$d/"
mut '.sdk_id = "inh" | .display_name = "Inh" | .packages = ["com.mixpanel.android.wrap"] | .in_house_wrapper = true' >"$d/inh.json"
dir_case "in-house package under a third-party package" L10 ERROR inh.json 'in-house package com.mixpanel.android.wrap overlaps package com.mixpanel.android of mixpanel' "$d"
mut '.sdk_id = "inh" | .display_name = "Inh" | .packages = ["com.inh"] | .in_house_wrapper = true' >"$d/inh.json"
mut '.sdk_id = "inh2" | .display_name = "Inh2" | .packages = ["com.inh"] | .in_house_wrapper = true' >"$d/inh2.json"
dir_case "two in-house entries with the same package" L10 ERROR inh.json 'overlaps package com.inh of inh2 (in-house)' "$d"
rm -f "$d/inh2.json"; clean_dir "disjoint in-house package" "$d"

# ---- L11 (WARN): a root containing another entry's root, not excluded ---------------------
d=$tmp/l11; mkdir -p "$d"; cp "$REG/_schema.json" "$base" "$d/"
mut '.sdk_id = "wide" | .display_name = "Wide" | .packages = ["com.mixpanel"]' >"$d/wide.json"
dir_case "root containing another entry's root" L11 WARN wide.json 'root com.mixpanel contains root com.mixpanel.android of mixpanel, and wide does not exclude it' "$d"
mut '.sdk_id = "wide" | .display_name = "Wide" | .packages = ["com.mixpanel"] | .detection = {"exclude_packages": ["com.mixpanel.android"]}' >"$d/wide.json"
out=$(bash "$LINT" $LINT_OPTS "$d" 2>&1)
assert_eq "" "$(printf '%s\n' "$out" | grep '^L11 ')" "L11: an exclude_packages item silences the warning"

# ---- L12: shared namespaces ----------------------------------------------------------------
mut '.detection = {"namespace_roots": ["com.google.android.gms"]}' >"$tmp/in"; lint_case "shared namespace as namespace_root" L12 mixpanel.json '"com.google.android.gms" is a shared namespace' <"$tmp/in"
mut '.detection = {"extra_packages": ["com.bytedance"]}' >"$tmp/in"; lint_case "shared namespace as extra_package" L12 mixpanel.json '"com.bytedance" is a shared namespace' <"$tmp/in"

# ---- L13 / L15: _audit-shared.json (mini registry: mixpanel + a reduced shared file) -----
mini_shared() { # mini_shared [<jq filter>]: the real shared file, legacy_flags reduced to mixpanel, then <filter>
  jq "(.legacy_flags = {\"find-trackers\": [.legacy_flags[\"find-trackers\"][] | select(.sdk_id == \"mixpanel\")], \"find-ads\": []})
      | (.library_roots |= map(select(startswith(\"com.facebook.\") or . == \"com.google.android.gms.ads.identifier\" | not)))
      | ${1:-.}" "$REG/_audit-shared.json"
}
d=$tmp/l13; mkdir -p "$d"; cp "$REG/_schema.json" "$base" "$d/"
mini_shared >"$d/_audit-shared.json"
out=$(bash "$LINT" $LINT_OPTS "$d" 2>&1); rc=$?
assert_eq 0 "$rc" "mini registry with _audit-shared.json: lint exits 0"
assert_eq "L15 WARN lint-registry.sh: L15 allowlist item com.google.android.gms.ads.identifier is no longer needed (not a library_root, or not under an identity root)" \
  "$(printf '%s\n' "$out" | grep -m1 '^L15 WARN')" "L15: a stale allowlist item is a WARN"
_T_CHECKS=$((_T_CHECKS + 1))
case "$(printf '%s\n' "$out" | tail -n 1)" in
  *"(skipped: L14)"*) pass_check "L14 skipped without ../scripts/detect-adwrapper.sh" ;;
  *) fail_check "L14 should be listed as skipped: $(printf '%s\n' "$out" | tail -n 1)" ;;
esac
l13() { # l13 <name> <jq filter> <message-substring> [<rule>]
  mini_shared "$2" >"$d/_audit-shared.json"
  dir_case "$1" "${4:-L13}" ERROR _audit-shared.json "$3" "$d"
}
l13 "category in two groups" '.category_groups.trackers += ["ads"]' 'category ads is in 2 group(s) of category_groups (ads, trackers)'
l13 "category in no group" '.category_groups.consent = []' 'category consent is in 0 group(s)'
l13 "group holding a non-category" '.category_groups.consent += ["push"]' 'category_groups.consent holds "push"'
l13 "legacy flag of a missing entry (segment before 7a)" '.legacy_flags["find-trackers"] += [{"flag":"segment","sdk_id":"segment","label":"Segment","section_prefix":"Segment"}]' \
  'flag "segment" points to sdk_id "segment", which is not a registry entry'
l13 "duplicate legacy flag" '.legacy_flags["find-trackers"] += .legacy_flags["find-trackers"]' 'legacy_flags.find-trackers: flag "mixpanel" appears 2 times'
l13 "legacy flag equal to an aspect flag" '.legacy_flags["find-trackers"][0].flag = "generic"' 'flag "generic" is an aspect flag of find-trackers'
l13 "legacy flags of an unknown tool" '.legacy_flags["find-sdks"] = []' 'legacy_flags.find-sdks: unknown tool'
l13 "duplicate hint id" '.hints += [.hints[0]]' 'hint id "generic-events" appears 2 times'
l13 "hint of an unknown tool" '.hints[0].tool = "find-api"' 'hint "generic-events": tool "find-api" not in'
l13 "hint flag of the other tool" '.hints[0].flag = "mediation"' 'hint "generic-events": flag "mediation" is not an aspect flag of find-trackers'
l13 "hint scope" '.hints[0].scope = "smali"' 'hint "generic-events": scope "smali" not in app_code, manifest'
l13 "hint match" '.hints[0].match = "regex"' 'hint "generic-events": match "regex" not in method, word, literal, exact'
l13 "match exact outside the manifest" '.hints[0].match = "exact"' 'hint "generic-events": match exact is only for scope manifest'
l13 "word token with _" '(.hints[] | select(.id == "coppa") | .tokens) += ["TAG_FOR_CHILD"]' 'hint "coppa": token "TAG_FOR_CHILD" contains _ and uses match=word'
l13 "library_root equal to an identity root" '.library_roots += ["com.mixpanel.android"]' 'library_root com.mixpanel.android equals an identity root of mixpanel' L15
l13 "library_root under an identity root" '.library_roots += ["com.mixpanel.android.util"]' \
  'library_root com.mixpanel.android.util is under the identity root com.mixpanel.android of mixpanel and is not in the L15 allowlist' L15

# ---- L14 (INFO): FROZEN detect-adwrapper tables without an owning entry ----------------------
d=$tmp/l14; mkdir -p "$d/registry" "$d/scripts"; cp "$REG/_schema.json" "$base" "$d/registry/"
mini_shared >"$d/registry/_audit-shared.json"
mut '.sdk_id = "mpb" | .display_name = "Mpb" | .packages = ["com.mixpanel.b"]' >"$d/registry/mpb.json"
cat >"$d/scripts/detect-adwrapper.sh" <<'ADW'
NETWORK_ROOTS='com/mixpanel/android|mixpanel
com/mixpanel|mp
com/nobody|nobody'
COMMON_ROOTS='android
com/gone'
ADW
out=$(bash "$LINT" $LINT_OPTS "$d/registry" 2>&1); rc=$?
assert_eq 0 "$rc" "L14 fixture: lint exits 0 (INFO only)"
assert_eq "L14 INFO detect-adwrapper.sh: NETWORK_ROOTS com/mixpanel (mp): shared by 2 entries (mixpanel, mpb)
L14 INFO detect-adwrapper.sh: NETWORK_ROOTS com/nobody (nobody): no owning registry entry
L14 INFO detect-adwrapper.sh: COMMON_ROOTS com/gone: no owning registry entry and no library_root" \
  "$(printf '%s\n' "$out" | grep '^L14 ')" "L14: unowned / shared NETWORK_ROOTS, uncovered COMMON_ROOTS (android is a library_root)"

# ---- the detection-only entries planned by DESIGN 3.3 (commit 7a) lint clean ----------------
d=$tmp/planned; mkdir -p "$d"; cp "$REG/_schema.json" "$d/"
cat >"$d/segment.json" <<'JSON'
{
  "$schema": "./_schema.json",
  "sdk_id": "segment",
  "display_name": "Segment Analytics",
  "vendor": "Twilio Segment",
  "category": "analytics",
  "description": "Detection-only (no targets).",
  "packages": [
    "com.segment.analytics"
  ],
  "detection": {
    "apis": [ {"class":"com.segment.analytics.Analytics","methods":["with","setSingletonInstance"],"role":"init"},
              {"class":"com.segment.analytics.Analytics","methods":["optOut"],"role":"consent"} ],
    "domains": ["api.segment.io", "api.segment.com", "cdn-settings.segment.com"]
  }
}
JSON
cat >"$d/flurry.json" <<'JSON'
{
  "$schema": "./_schema.json",
  "sdk_id": "flurry",
  "display_name": "Flurry Analytics",
  "vendor": "Yahoo",
  "category": "analytics",
  "description": "Detection-only (no targets).",
  "packages": [
    "com.flurry.android",
    "com.flurry.sdk"
  ],
  "detection": {
    "marker_classes": ["com.flurry.android.FlurryAgent"],
    "apis": [ {"class":"com.flurry.android.FlurryAgent$Builder","methods":["<init>","build"],"role":"init"},
              {"class":"com.flurry.android.FlurryAgent","methods":["logEvent","endTimedEvent","logPayment"],"role":"event"},
              {"class":"com.flurry.android.FlurryAgent","methods":["setUserId","setAge","setGender"],"role":"identity"} ],
    "domains": ["flurry.com"],
    "id_prefixes": [{"prefix": "FLURRY_", "label": "flurry_key"}],
    "manifest_names": ["FLURRY_API_KEY"],
    "note": "id_prefixes / manifest_names: lint fixture values only"
  }
}
JSON
out=$(bash "$LINT" "$d" 2>&1); rc=$?
assert_eq 0 "$rc" "DESIGN 3.3 segment + flurry entries lint clean"
assert_eq "" "$(printf '%s\n' "$out" | grep -E '^(L[0-9]+|SCHEMA) ')" "DESIGN 3.3 entries: no finding at all"

t_done
