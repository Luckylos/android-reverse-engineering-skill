#!/usr/bin/env bash
# t_categories.sh -- T-CAT (DESIGN 2.3, invariant I6): the category groups of
# REG/_audit-shared.json are the ones registry-scan.py hard-codes (ADS_CATEGORIES,
# TRACKER_CATEGORIES; consent = {consent}); they partition the category enum of
# _schema.json; the `group` column of `registry-query.sh rows` follows them for every
# entry (the ps1 twin prints the same bytes: parity/t_parity.sh). Also: tool_groups name
# existing groups, every legacy_flags sdk_id exists, and _audit-shared.json validates
# against _audit-shared.schema.json when python jsonschema is available.
# requires: NS/registry-query.sh REG/_audit-shared.json
# requires: cmd: have_jq16
# requires: cmd: command -v python3 >/dev/null
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
export LC_ALL=C

SHARED=$REG/_audit-shared.json
mktemp_dir tmp

# registry-scan.py constants, read with the Python parser (never imported/executed)
python3 - "$NS/registry-scan.py" >"$tmp/py" <<'PY' || die "cannot read the registry-scan.py constants"
import ast, sys
tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
want = {"ADS_CATEGORIES": "ads", "TRACKER_CATEGORIES": "trackers"}
for node in tree.body:
    if isinstance(node, ast.Assign) and len(node.targets) == 1 and getattr(node.targets[0], "id", None) in want:
        for v in sorted(ast.literal_eval(node.value)):
            print(want[node.targets[0].id] + "\t" + v)
PY
printf 'consent\tconsent\n' >>"$tmp/py"
sort "$tmp/py" >"$tmp/py.sorted"
jq -r '.category_groups | to_entries[] | .key as $g | .value[] | "\($g)\t\(.)"' "$SHARED" | sort >"$tmp/shared.sorted"
assert_files_eq "$tmp/py.sorted" "$tmp/shared.sorted" "category_groups == registry-scan.py ADS/TRACKER_CATEGORIES + consent"
assert_eq "ads trackers consent" "$(jq -r '.category_groups | keys_unsorted | join(" ")' "$SHARED")" "groups: ads, trackers, consent"

jq -r '.properties.category.enum[]' "$REG/_schema.json" | sort >"$tmp/enum"
cut -f2 "$tmp/shared.sorted" | sort >"$tmp/grouped"
assert_files_eq "$tmp/enum" "$tmp/grouped" "every category of the schema enum is in exactly one group"

assert_eq "" "$(jq -r --slurpfile s "$SHARED" '.tool_groups[][] | select(. as $g | $s[0].category_groups | has($g) | not)' "$SHARED")" \
  "tool_groups only name existing groups"
run_bash "$NS/registry-query.sh" --registry "$REG" rows >"$tmp/rows" 2>"$tmp/rows.err"
assert_eq 0 "$?" "registry-query rows on the real registry"
awk -F '\t' '$3 == "file" { print $1 }' "$tmp/rows" | sort >"$tmp/ids"
jq -r '.legacy_flags[][] | .sdk_id' "$SHARED" | sort -u >"$tmp/legacy"
assert_eq "" "$(comm -23 "$tmp/legacy" "$tmp/ids")" "every legacy_flags sdk_id is a registry entry"

# group column == category_groups[category] (else "other"), entry by entry
awk -F '\t' 'NR == FNR { g[$2] = $1; next }
  $3 == "group" { want = ($2 in g) ? g[$2] : "other"; if ($4 != want) print $1 ": group " $4 " != " want }' \
  "$tmp/shared.sorted" "$tmp/rows" >"$tmp/badgroups"
assert_eq "" "$(cat "$tmp/badgroups")" "rows: group column follows category_groups for every entry"
assert_eq 0 "$(awk -F '\t' '$3 == "group" && $4 == "other"' "$tmp/rows" | wc -l | tr -d ' ')" "no registry entry falls in group other"
run_bash "$NS/registry-query.sh" --registry "$TESTS_DIR/fixtures/registry-mini" rows >"$tmp/mini" 2>/dev/null
assert_eq "other" "$(awk -F '\t' '$1 == "aaa-first" && $3 == "group" { print $4 }' "$tmp/mini")" "unknown category -> group other"

if python3 -c 'import jsonschema' >/dev/null 2>&1; then
  python3 - "$REG" >"$tmp/schema" 2>&1 <<'PY'
import json, os, sys
import jsonschema
d = sys.argv[1]
schema = json.load(open(os.path.join(d, "_audit-shared.schema.json"), encoding="utf-8"))
jsonschema.Draft7Validator.check_schema(schema)
data = json.load(open(os.path.join(d, "_audit-shared.json"), encoding="utf-8"))
for e in jsonschema.Draft7Validator(schema).iter_errors(data):
    print("/".join(str(p) for p in e.absolute_path) + ": " + e.message[:200])
PY
  assert_eq "" "$(cat "$tmp/schema")" "_audit-shared.json validates against _audit-shared.schema.json"
else
  echo "note: python jsonschema not installed, schema validation of _audit-shared.json skipped"
fi
t_done
