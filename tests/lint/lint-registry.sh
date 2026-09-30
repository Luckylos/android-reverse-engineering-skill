#!/usr/bin/env bash
# tests/lint/lint-registry.sh -- dev-only lint of the SDK registry (DESIGN 4.6).
# Not shipped with the plugin, so it has no .ps1 twin; it may use jq regexes.
#
# Usage: lint-registry.sh [--quiet] [REGISTRY_DIR]
#   REGISTRY_DIR  default: <plugin>/skills/sdk-neutralizer/registry
#
# Rules implemented here (L5-L15 arrive with the `detection` schema, DESIGN 10 commit 5):
#   L1  UTF-8 without BOM, LF only, final newline, exactly one JSON document per
#       file, root is an object                         (every *.json, `_` files too)
#   L2  sdk_id matches ^[a-z0-9-]+$, is unique, equals the file name
#       (historical exception: consent-umptcf.json -> google-ump-consent)
#   L3  display_name printable ASCII without ':' '|' or newline; vendor is a
#       string; category is in the enum
#   L4  targets absent or an object (never null); when absent, no
#       manifest_components / protected_patterns (a detection-only entry must not
#       carry neutralizer instructions)
#   SCHEMA  full JSON-schema validation against _schema.json, only when
#       `python3 -c 'import jsonschema'` works (dev convenience; otherwise skipped).
#       Message: `<instance path> [<schema path>]: <jsonschema message, cut at 200>`;
#       the schema path (e.g. `then/not`, `properties/display_name/pattern`) names
#       the failing constraint independently of the jsonschema version (3.x and 4.x
#       word the messages differently, and a long instance repr can push the
#       distinguishing text past the cut)
# L2-L4 and SCHEMA apply to entry files only (names not starting with `_`).
#
# Output: one line per finding, `<rule> ERROR|WARN <file>: <message>`, then a summary.
# Exit: 0 = no errors (warnings allowed), 1 = errors or bad usage,
#       77 = skipped (jq < 1.6 or jq without regex support).
set -uo pipefail
export LC_ALL=C

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../lib/common.sh
. "$here/../lib/common.sh"

quiet=0
dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) quiet=1 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    -*) echo "lint-registry: unknown option $1" >&2; exit 1 ;;
    *) dir=$1 ;;
  esac
  shift
done
dir=${dir:-$REG}
[ -d "$dir" ] || { echo "lint-registry: registry directory not found: $dir" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || skip "lint-registry: jq not found"
have_jq16 || skip "lint-registry: jq >= 1.6 required"
[ "$(jq -n '"a" | test("a")' 2>/dev/null)" = true ] ||
  skip "lint-registry: WARN this jq has no regex support (Oniguruma); lint skipped"

CATEGORIES='["ads","ads_mediation","analytics","attribution","crash_reporting","social","consent"]'
errors=0
warnings=0
nfiles=0
report() { # report <rule> <ERROR|WARN> <file> <message>
  if [ "$2" = ERROR ]; then errors=$((errors + 1)); else warnings=$((warnings + 1)); fi
  [ "$quiet" = 1 ] || printf '%s %s %s: %s\n' "$1" "$2" "$3" "$4"
}

mktemp_dir tmp
: >"$tmp/ids"
have_iconv=0
command -v iconv >/dev/null 2>&1 && have_iconv=1

for f in "$dir"/*.json; do
  [ -e "$f" ] || continue
  nfiles=$((nfiles + 1))
  b=$(basename "$f")
  ok=1
  # ---- L1 ----------------------------------------------------------------------
  if [ ! -s "$f" ]; then report L1 ERROR "$b" "empty file"; continue; fi
  if [ "$(head -c 3 "$f" | od -An -tx1 | tr -d ' \n')" = efbbbf ]; then
    report L1 ERROR "$b" "BOM not allowed"; ok=0
  fi
  if [ "$(tr -d '\r' <"$f" | wc -c)" -ne "$(wc -c <"$f")" ]; then
    report L1 ERROR "$b" "CR (CRLF) line endings not allowed"; ok=0
  fi
  if [ "$(tail -c 1 "$f" | od -An -tx1 | tr -d ' \n')" != 0a ]; then
    report L1 ERROR "$b" "missing final newline"
  fi
  if [ "$have_iconv" = 1 ] && ! iconv -f UTF-8 -t UTF-8 <"$f" >/dev/null 2>&1; then
    report L1 ERROR "$b" "not valid UTF-8"; ok=0
  fi
  [ "$ok" = 1 ] || continue
  if ! ndocs=$(jq -n '[inputs] | length' "$f" 2>"$tmp/err"); then
    report L1 ERROR "$b" "invalid JSON: $(head -n 1 "$tmp/err")"; continue
  fi
  if [ "$ndocs" != 1 ]; then report L1 ERROR "$b" "$ndocs JSON documents (exactly one expected)"; continue; fi
  if [ "$(jq -r 'type' "$f")" != object ]; then report L1 ERROR "$b" "root is not an object"; continue; fi

  case "$b" in _*) continue ;; esac
  # ---- L2-L4 (entries) --------------------------------------------------------------
  jq -r --arg file "$b" --argjson cats "$CATEGORIES" '
    def err(r; m): "\(r)\t\(m)";
    ($file | rtrimstr(".json")) as $stem
    | (if $file == "consent-umptcf.json" then "google-ump-consent" else $stem end) as $want
    # L2
    | (if (.sdk_id | type) != "string" then err("L2"; "sdk_id missing or not a string")
       elif (.sdk_id | test("\\A[a-z0-9-]+\\z") | not) then err("L2"; "sdk_id \(.sdk_id | @json) does not match ^[a-z0-9-]+$")
       elif .sdk_id != $want then err("L2"; "sdk_id \(.sdk_id | @json) differs from the file name (expected \($want | @json))")
       else empty end),
    # L3
      (if (.display_name | type) != "string" then err("L3"; "display_name missing or not a string")
       elif (.display_name | test("\\A[ -~]+\\z") | not) then err("L3"; "display_name must be printable ASCII without newline")
       elif (.display_name | test("[:|]")) then err("L3"; "display_name must not contain : or |")
       else empty end),
      (if (.vendor | type) != "string" then err("L3"; "vendor missing or not a string") else empty end),
      (if (.category | type) != "string" or ((.category) as $c | $cats | index([$c]) | not)
       then err("L3"; "category \(.category | @json) not in \($cats | join(","))") else empty end),
    # L4
      (if has("targets") then
         (if (.targets | type) != "object" then err("L4"; "targets present but \(.targets | type) (must be an object, never null)") else empty end)
       else
         (if has("manifest_components") then err("L4"; "entry without targets (detection-only) must not have manifest_components") else empty end),
         (if has("protected_patterns") then err("L4"; "entry without targets (detection-only) must not have protected_patterns") else empty end)
       end)
  ' "$f" >"$tmp/findings" 2>"$tmp/err" || report L2 ERROR "$b" "jq failed: $(head -n 1 "$tmp/err")"
  while IFS="$(printf '\t')" read -r rule msg; do
    [ -n "$rule" ] && report "$rule" ERROR "$b" "$msg"
  done <"$tmp/findings"
  id=$(jq -r 'if (.sdk_id | type) == "string" then .sdk_id else empty end' "$f")
  [ -n "$id" ] && printf '%s\t%s\n' "$id" "$b" >>"$tmp/ids"
done

# L2 uniqueness across files
sort "$tmp/ids" | awk -F '\t' '
  $1 == prev { printf "%s\t%s\t%s\n", $1, pf, $2 } { prev = $1; pf = $2 }' >"$tmp/dups"
while IFS="$(printf '\t')" read -r id f1 f2; do
  [ -n "$id" ] && report L2 ERROR "$f2" "duplicate sdk_id \"$id\" (also in $f1)"
done <"$tmp/dups"

# SCHEMA (optional)
schema_state=skipped
if [ -f "$dir/_schema.json" ] && command -v python3 >/dev/null 2>&1 &&
   python3 -c 'import jsonschema' >/dev/null 2>&1; then
  schema_state=jsonschema
  python3 - "$dir" >"$tmp/schema" 2>&1 <<'PY'
import glob, json, os, sys
import jsonschema
d = sys.argv[1]
with open(os.path.join(d, "_schema.json"), encoding="utf-8") as fh:
    schema = json.load(fh)
validator = jsonschema.validators.validator_for(schema)(schema)
for path in sorted(glob.glob(os.path.join(d, "*.json"))):
    name = os.path.basename(path)
    if name.startswith("_"):
        continue
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except Exception:
        continue  # already reported by L1
    for e in sorted(validator.iter_errors(doc), key=lambda e: list(e.absolute_path)):
        loc = "/".join(str(p) for p in e.absolute_path) or "(root)"
        spath = "/".join(str(p) for p in e.schema_path)
        print("%s\t%s [%s]: %s" % (name, loc, spath, e.message.replace("\n", " ")[:200]))
PY
  while IFS="$(printf '\t')" read -r f msg; do
    [ -n "$f" ] && report SCHEMA ERROR "$f" "$msg"
  done <"$tmp/schema"
fi

echo "lint-registry: $nfiles file(s), $errors error(s), $warnings warning(s) [rules L1-L4, schema: $schema_state] ($dir)"
[ "$errors" -eq 0 ]
