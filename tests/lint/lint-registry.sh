#!/usr/bin/env bash
# tests/lint/lint-registry.sh -- dev-only lint of the SDK registry (DESIGN 4.6).
# Not shipped with the plugin, so it has no .ps1 twin; it may use jq regexes.
#
# Usage: lint-registry.sh [--quiet] [--no-schema] [REGISTRY_DIR]
#   REGISTRY_DIR  default: <plugin>/skills/sdk-neutralizer/registry
#   --no-schema   skip the optional JSON-schema validation (SCHEMA; faster self-tests)
#
# Rules:
#   L1  UTF-8 without BOM, LF only, final newline, exactly one JSON document per
#       file, root is an object                         (every *.json, `_` files too)
#   L2  sdk_id matches ^[a-z0-9-]+$, is unique, equals the file name
#       (historical exception: consent-umptcf.json -> google-ump-consent)
#   L3  display_name printable ASCII without ':' '|' or newline; vendor is a
#       string; category is in the enum
#   L4  targets absent or an object (never null); when absent, no
#       manifest_components / protected_patterns (a detection-only entry must not
#       carry neutralizer instructions)
#   L5  top-level keys, `detection` keys and the keys of detection.apis[] /
#       detection.id_prefixes[] items are the ones _schema.json declares (it has
#       additionalProperties:false at each of those levels); detection is an object
#   L6  no two keys of one object differ only by case, at any depth (PowerShell 5.1
#       ConvertFrom-Json fails on them)                 (every *.json, `_` files too)
#   L7  syntax: package names (`packages` and the four package lists of detection),
#       marker_classes (top-level: no '$'), apis (class, methods, role), domains,
#       manifest_names, id_prefixes; no duplicate item in a list. The patterns, the
#       role enum and the prefix minimum length are read from _schema.json
#   L8  detection.extra_packages disjoint from packages; every
#       detection.exclude_packages item is strictly under a root of the entry
#       (packages or extra_packages)
#   L9  the keys packages, sdk_id and in_house_wrapper appear once, at the top level
#       only; in the text, `"packages": [` ends its line, each item is a plain string
#       on its own line, and the awk fallback of registry-query (DESIGN 4.4) reads the
#       same packages / sdk_id / in_house_wrapper values as jq (rule R6)
#   L10 the packages of in_house_wrapper entries are disjoint (no equal value, none
#       under another) from the packages of the other entries, in-house or not
#   L11 (WARN) a root A (packages or extra_packages) of one entry is a strict prefix of
#       a root B of another entry and A's entry does not exclude B (exclude_packages)
#   L12 namespace_roots and extra_packages never hold a shared namespace (SHARED_NS)
#   L13 _audit-shared.json: every category of the enum is in exactly one group (and
#       groups only hold enum categories); legacy_flags only for known tools, every
#       legacy_flags sdk_id exists, a flag is unique per tool and is not an aspect
#       flag of that tool; hint ids unique; hint tool, flag, scope and match valid
#       (exact only for scope manifest); no token containing '_' uses match=word
#   L14 (INFO) roots of the FROZEN detect-adwrapper tables (../scripts/detect-adwrapper.sh
#       next to the registry) without an owning entry: a NETWORK_ROOTS root that no
#       entry root (packages, extra_packages, namespace_roots) equals, contains or sits
#       under, or that several entries share; a COMMON_ROOTS root covered neither by an
#       entry root nor by library_roots. A report for step 2 (DESIGN Q3), never an error
#   L15 library_roots never equal an identity root (packages or extra_packages) of an
#       entry; a library_root under an identity root must be in LIBROOT_ALLOW below
#       (WARN for an allowlist item that is no longer needed)
#   SCHEMA  full JSON-schema validation against _schema.json, only when
#       `python3 -c 'import jsonschema'` works (dev convenience; otherwise skipped).
#       Message: `<instance path> [<schema path>]: <jsonschema message, cut at 200>`;
#       the schema path (e.g. `then/not`, `properties/display_name/pattern`) names
#       the failing constraint independently of the jsonschema version (3.x and 4.x
#       word the messages differently, and a long instance repr can push the
#       distinguishing text past the cut)
# L2-L5, L7-L9 and SCHEMA apply to entry files only (names not starting with `_`).
# L13 and L15 need _audit-shared.json, L14 also needs ../scripts/detect-adwrapper.sh,
# L5/L7 need _schema.json (the one of the default registry when the directory has
# none); a rule whose input is missing is listed as skipped in the summary line.
#
# Output: one line per finding, `<rule> ERROR|WARN|INFO <file>: <message>`, then a summary.
# Exit: 0 = no errors (warnings and infos allowed), 1 = errors or bad usage,
#       77 = skipped (jq < 1.6 or jq without regex support).
set -uo pipefail
export LC_ALL=C

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../lib/common.sh
. "$here/../lib/common.sh"

quiet=0
noschema=0
dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) quiet=1 ;;
    --no-schema) noschema=1 ;;
    -h|--help) sed -n '2,67p' "$0"; exit 0 ;;
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

# L12: namespaces shared by several vendors/products; never a namespace_root or an
# extra_package of one entry (DESIGN 4.6).
SHARED_NS='["com.google","com.google.android","com.google.android.gms","com.facebook",
  "com.unity3d","com.amazon","com.yandex","com.bytedance","com.my","com.microsoft","com.android"]'

# L13: the tools of the audit and their aspect flags (the non-SDK flags of the legacy
# find-trackers.sh / find-ads.sh CLIs, 4c166fe). A hint flag must be one of them;
# a legacy_flags flag must not be one of them.
TOOL_FLAGS='{"find-trackers":["generic","endpoints","manifest"],
  "find-ads":["formats","mediation","consent","manifest"]}'

# L15 allowlist: library_roots that sit UNDER an identity root of an entry, on purpose.
# One item per line: <library_root> <TAB-or-spaces> # <reason>.
LIBROOT_ALLOW=$(sed -e 's/[[:space:]]*#.*$//' -e '/^$/d' <<'ALLOW'
com.google.android.gms.ads.identifier   # AdvertisingIdClient: used by every SDK; google-admob excludes it (DESIGN 3.2)
com.facebook.soloader                   # Meta open-source libraries, not the Facebook SDK (DESIGN 2.3):
com.facebook.react                      #   with the longest-root rule they are library, not facebook identity
com.facebook.fresco                     #
com.facebook.imagepipeline              #
com.facebook.drawee                     #
com.facebook.yoga                       #
com.facebook.hermes                     #
com.facebook.jni                        #
com.facebook.infer                      #
com.facebook.flipper                    #
com.facebook.device                     #   (com/facebook/device is present on blockcraft)
ALLOW
)
LIBROOT_ALLOW_JSON=$(printf '%s\n' "$LIBROOT_ALLOW" | jq -R . | jq -sc .)

errors=0
warnings=0
infos=0
nfiles=0
skipped=""
report() { # report <rule> <ERROR|WARN|INFO> <file> <message>
  case "$2" in
    ERROR) errors=$((errors + 1)) ;;
    WARN)  warnings=$((warnings + 1)) ;;
    *)     infos=$((infos + 1)) ;;
  esac
  [ "$quiet" = 1 ] || printf '%s %s %s: %s\n' "$1" "$2" "$3" "$4"
}
# report_lines <file> <findings-file>: lines `<rule>\t<level>\t<message>`
report_lines() {
  while IFS="$(printf '\t')" read -r _rule _lvl _msg; do
    [ -n "$_rule" ] && report "$_rule" "$_lvl" "$1" "$_msg"
  done <"$2"
}

mktemp_dir tmp
: >"$tmp/ids"
: >"$tmp/entries.list"
have_iconv=0
command -v iconv >/dev/null 2>&1 && have_iconv=1

# ---- schema tables for L5 / L7 (from _schema.json: one source of truth) -------------
schema_file=$dir/_schema.json
[ -f "$schema_file" ] || schema_file=$REG/_schema.json
if ! jq -c '
    def anchor: if startswith("^") and endswith("$") then "\\A" + .[1:-1] + "\\z" else . end;
    { top: (.properties | keys_unsorted),
      det: (.definitions.detection.properties | keys_unsorted),
      api: (.definitions.api_fact.properties | keys_unsorted),
      idp: (.definitions.detection.properties.id_prefixes.items.properties | keys_unsorted),
      pkg: (.definitions.package_list.items.pattern | anchor),
      marker: (.definitions.top_level_class.pattern | anchor),
      host: (.definitions.host.pattern | anchor),
      apiclass: (.definitions.api_fact.properties.class.pattern | anchor),
      method: (.definitions.api_fact.properties.methods.items.pattern | anchor),
      roles: .definitions.api_fact.properties.role.enum,
      mname: (.definitions.detection.properties.manifest_names.items.pattern | anchor),
      label: (.definitions.detection.properties.id_prefixes.items.properties.label.pattern | anchor),
      prefixmin: .definitions.detection.properties.id_prefixes.items.properties.prefix.minLength }
    | if any(.[]; . == null) then error("incomplete") else . end' "$schema_file" >"$tmp/tables" 2>/dev/null; then
  report L5 ERROR "$(basename "$schema_file")" "cannot read the allowed keys / patterns (properties, definitions.detection, package_list, top_level_class, host, api_fact) from $schema_file; L5 and L7 skipped"
  echo null >"$tmp/tables"
  skipped="$skipped L5 L7"
fi

# ---- per-entry rules (L2-L5, L7-L9, L12) as one jq program -------------------------
cat >"$tmp/entry.jq" <<'JQ'
def err(r; m): "\(r)\tERROR\t\(m)";
def jl: map(tojson) | join(", ");
def under($a; $b): $a | startswith($b + ".");
def arr($v): if ($v | type) == "array" then $v[] else empty end;
def pathstr: if length == 0 then "(root)" else map(if type == "number" then "[\(.)]" else ".\(.)" end) | join("") end;
# L7 list of strings: strlist(name; value; regex; what)
def strlist($name; $v; $re; $what):
  if $v == null then empty
  elif ($v | type) != "array" then err("L7"; "\($name) must be an array, not \($v | type)")
  else
    ($v[] | select(type != "string") | err("L7"; "\($name): item \(tojson) is not a string")),
    ($v[] | strings | select(test($re) | not) | err("L7"; "\($name): \(tojson) is not a valid \($what)")),
    ([$v | group_by(.)[] | select(length > 1) | .[0]] | select(length > 0) | err("L7"; "\($name): duplicate item(s) \(jl)"))
  end;

$tables[0] as $T
| (if (.sdk_id | type) == "string" then .sdk_id else "" end) as $id
| ([
($file | rtrimstr(".json")) as $stem
| (if $file == "consent-umptcf.json" then "google-ump-consent" else $stem end) as $want
| (if (.detection | type) == "object" then .detection else {} end) as $d
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
   end),
# L5
  (if $T == null then empty else
     ((keys_unsorted - $T.top) | select(length > 0) | err("L5"; "top-level key(s) not in the schema: \(jl)")),
     (if has("detection") and (.detection | type) != "object" then
        err("L5"; "detection must be an object, not \(.detection | type)") else empty end),
     (($d | keys_unsorted) - $T.det | select(length > 0) | err("L5"; "detection key(s) not in the schema: \(jl)")),
     ($d.apis | if type == "array" then to_entries[] else empty end
      | .key as $i | .value | objects | (keys_unsorted - $T.api) | select(length > 0)
      | err("L5"; "detection.apis[\($i)] key(s) not in the schema: \(jl)")),
     ($d.id_prefixes | if type == "array" then to_entries[] else empty end
      | .key as $i | .value | objects | (keys_unsorted - $T.idp) | select(length > 0)
      | err("L5"; "detection.id_prefixes[\($i)] key(s) not in the schema: \(jl)"))
   end),
# L7
  (if $T == null then empty else
     strlist("packages"; .packages; $T.pkg; "package name"),
     strlist("detection.extra_packages"; $d.extra_packages; $T.pkg; "package name"),
     strlist("detection.exclude_packages"; $d.exclude_packages; $T.pkg; "package name"),
     strlist("detection.namespace_roots"; $d.namespace_roots; $T.pkg; "package name"),
     strlist("detection.adapter_packages"; $d.adapter_packages; $T.pkg; "package name"),
     ($d.marker_classes | arrays | .[] | strings | select(contains("$"))
      | err("L7"; "detection.marker_classes: \(tojson) must be a top-level class (no '$')")),
     strlist("detection.marker_classes"; ($d.marker_classes | if type == "array" then map(select(type != "string" or (contains("$") | not))) else . end);
             $T.marker; "fully qualified top-level class name"),
     strlist("detection.domains"; $d.domains; $T.host; "host name (lowercase, at least one dot)"),
     strlist("detection.manifest_names"; $d.manifest_names; $T.mname; "android:name value"),
     (if $d.apis == null then empty
      elif ($d.apis | type) != "array" then err("L7"; "detection.apis must be an array, not \($d.apis | type)")
      else $d.apis | to_entries[] | .key as $i | .value as $a | "detection.apis[\($i)]" as $n
        | if ($a | type) != "object" then err("L7"; "\($n) must be an object, not \($a | type)")
          else
            (if ($a.class | type) != "string" then err("L7"; "\($n).class missing or not a string")
             elif ($a.class | test($T.apiclass) | not) then err("L7"; "\($n).class \($a.class | tojson) is not a valid fully qualified class name")
             else empty end),
            (if ($a.methods | type) != "array" or ($a.methods | length) == 0 then err("L7"; "\($n).methods must be a non-empty array")
             else strlist("\($n).methods"; $a.methods; $T.method; "method name (Java identifier or <init>)") end),
            (if ($a.role | type) == "string" and ($a.role | IN($T.roles[])) then empty
             else err("L7"; "\($n).role \($a.role | tojson) not in \($T.roles | join(","))") end)
          end
      end),
     (if $d.id_prefixes == null then empty
      elif ($d.id_prefixes | type) != "array" then err("L7"; "detection.id_prefixes must be an array, not \($d.id_prefixes | type)")
      else $d.id_prefixes | to_entries[] | .key as $i | .value as $p | "detection.id_prefixes[\($i)]" as $n
        | if ($p | type) != "object" then err("L7"; "\($n) must be an object, not \($p | type)")
          else
            (if ($p.prefix | type) != "string" or ($p.prefix | length) < $T.prefixmin
             then err("L7"; "\($n).prefix must be a string of at least \($T.prefixmin) characters") else empty end),
            (if ($p.label | type) != "string" or ($p.label | test($T.label) | not)
             then err("L7"; "\($n).label \($p.label | tojson) does not match [a-z0-9_]+") else empty end)
          end
      end)
   end),
# L8
  ([arr(.packages) | strings] as $pk
   | [arr($d.extra_packages) | strings] as $ex
   | ($ex[] | select(IN($pk[])) | err("L8"; "detection.extra_packages \(tojson) is already in packages (must be disjoint)")),
     (arr($d.exclude_packages) | strings | . as $x
      | select(any(($pk + $ex)[]; under($x; .)) | not)
      | err("L8"; "detection.exclude_packages \(tojson) is not strictly under a root of this entry (packages or extra_packages)"))),
# L12
  (arr($d.namespace_roots) | strings | select(IN($shared[]))
   | err("L12"; "detection.namespace_roots \(tojson) is a shared namespace (never a namespace root)")),
  (arr($d.extra_packages) | strings | select(IN($shared[]))
   | err("L12"; "detection.extra_packages \(tojson) is a shared namespace (never an identity root)")),
# L9: keys only at the top level ...
  ([paths | select(length > 1 and (.[-1] | type) == "string"
                   and (.[-1] | IN("packages", "sdk_id", "in_house_wrapper")))][]
   | err("L9"; "key \(.[-1] | tojson) must appear only at the top level (found at \(pathstr))")),
# ... and the text read by the awk fallback (lines of $l9, see l9.awk) agrees with jq
  ($l9 | split("\n") | map(select(length > 0) | split("\t"))) as $L
  | ([$L[] | select(.[0] == "N") | {(.[1]): (.[2] | tonumber)}] | add // {}) as $cnt
  | ([$L[] | select(.[0] == "P") | .[1]]) as $tp
  | ([$L[] | select(.[0] == "S") | .[1]]) as $ts
  | ($L | any(.[0] == "I")) as $ti
  | ($L[] | select(.[0] == "E") | err("L9"; .[1])),
    (if $cnt.packages != 1 then err("L9"; "\"packages\": appears \($cnt.packages) times in the text (exactly once, at the top level)")
     elif ([$L[] | select(.[0] == "E")] | length) == 0 and (.packages | type) == "array" and $tp != .packages
     then err("L9"; "the awk fallback reads packages \($tp | tojson), jq reads \(.packages | tojson) (escapes or non-string items?)")
     else empty end),
    (if $cnt.sdk_id != 1 then err("L9"; "\"sdk_id\": appears \($cnt.sdk_id) times in the text (exactly once, at the top level)")
     elif (.sdk_id | type) == "string" and $ts != [.sdk_id]
     then err("L9"; "the awk fallback reads sdk_id \($ts | first // "nothing" | tojson), jq reads \(.sdk_id | tojson)")
     else empty end),
    (if $cnt.in_house_wrapper > 1 then err("L9"; "\"in_house_wrapper\": appears \($cnt.in_house_wrapper) times in the text (at most once, at the top level)")
     elif $ti != (.in_house_wrapper == true)
     then err("L9"; "the awk fallback reads in_house_wrapper=\($ti), jq reads \(.in_house_wrapper | tojson)")
     else empty end)
  ][], "ID\t\($id)")
JQ

# L9 text scan: what the awk fallback of registry-query.sh sees (DESIGN 4.4, R6).
# Output lines: P<TAB>package, S<TAB>first sdk_id value, I (an in_house_wrapper true
# line), N<TAB>key<TAB>count, E<TAB>style error.
cat >"$tmp/l9.awk" <<'AWK'
function cnt(s, re,    n) { n = 0; while (match(s, re)) { n++; s = substr(s, RSTART + RLENGTH) } return n }
{
  line = $0
  if (inarr) {
    if (line ~ /^[ \t]*\][ \t]*,?[ \t]*$/) { inarr = 0; next }
    if (line ~ /^[ \t]*"[^"\\]*"[ \t]*,?[ \t]*$/) {
      v = line; sub(/^[ \t]*"/, "", v); sub(/"[ \t]*,?[ \t]*$/, "", v); print "P\t" v; next
    }
    print "E\tline " NR ": a packages item must be a plain string alone on its line (\"pkg\" or \"pkg\",)"
    inarr = 0
  }
  n = cnt(line, "\"packages\"[ \t]*:")
  if (n > 0) {
    if (npk == 0) {
      if (line ~ /^[ \t]*"packages"[ \t]*:[ \t]*\[[ \t]*$/) inarr = 1
      else print "E\tline " NR ": `\"packages\": [` must end its line (one item per line follows)"
    }
    npk += n
  }
  nsid += cnt(line, "\"sdk_id\"[ \t]*:")
  if (!gotid && match(line, /"sdk_id"[ \t]*:[ \t]*"[^"]*"/)) {
    v = substr(line, RSTART, RLENGTH); sub(/^"sdk_id"[ \t]*:[ \t]*"/, "", v); sub(/"$/, "", v)
    print "S\t" v; gotid = 1
  }
  nih += cnt(line, "\"in_house_wrapper\"[ \t]*:")
  if (line ~ /"in_house_wrapper"[ \t]*:[ \t]*true/) ih = 1
}
END {
  if (inarr) print "E\tthe packages array is not closed by a `]` line"
  print "N\tpackages\t" (npk + 0); print "N\tsdk_id\t" (nsid + 0); print "N\tin_house_wrapper\t" (nih + 0)
  if (ih) print "I"
}
AWK

# L6: case-colliding keys at any depth
L6_JQ='([[]] + [paths(type == "object")])[] as $p
  | getpath($p) | keys_unsorted | group_by(ascii_downcase)[] | select(length > 1)
  | "L6\tERROR\tkeys differing only by case at \($p | if length == 0 then "(root)" else map(if type == "number" then "[\(.)]" else ".\(.)" end) | join("") end): \(map(tojson) | join(", "))"'

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
  # root type (first line) + L6 (every file), in one jq run
  jq -r 'type, (if type == "object" then '"$L6_JQ"' else empty end)' "$f" >"$tmp/findings" 2>"$tmp/err" ||
    report L6 ERROR "$b" "jq failed: $(head -n 1 "$tmp/err")"
  if [ "$(head -n 1 "$tmp/findings")" != object ]; then report L1 ERROR "$b" "root is not an object"; continue; fi
  sed 1d "$tmp/findings" >"$tmp/l6"
  report_lines "$b" "$tmp/l6"

  case "$b" in _*) continue ;; esac
  # ---- L2-L5, L7-L9, L12 (entries) ----------------------------------------------
  awk -f "$tmp/l9.awk" "$f" >"$tmp/l9" 2>"$tmp/err" || report L9 ERROR "$b" "awk failed: $(head -n 1 "$tmp/err")"
  jq -r --arg file "$b" --argjson cats "$CATEGORIES" --argjson shared "$SHARED_NS" \
    --slurpfile tables "$tmp/tables" --rawfile l9 "$tmp/l9" \
    -f "$tmp/entry.jq" "$f" >"$tmp/findings" 2>"$tmp/err" ||
    report L2 ERROR "$b" "jq failed: $(head -n 1 "$tmp/err")"
  # the last line is `ID<TAB><sdk_id>` (empty when sdk_id is not a string)
  sed '$d' "$tmp/findings" >"$tmp/l6"
  report_lines "$b" "$tmp/l6"
  id=$(tail -n 1 "$tmp/findings" | sed -n 's/^ID\t//p')
  [ -n "$id" ] && printf '%s\t%s\n' "$id" "$b" >>"$tmp/ids"
  printf '%s\n' "$f" >>"$tmp/entries.list"
done

# L2 uniqueness across files
sort "$tmp/ids" | awk -F '\t' '
  $1 == prev { printf "%s\t%s\t%s\n", $1, pf, $2 } { prev = $1; pf = $2 }' >"$tmp/dups"
while IFS="$(printf '\t')" read -r id f1 f2; do
  [ -n "$id" ] && report L2 ERROR "$f2" "duplicate sdk_id \"$id\" (also in $f1)"
done <"$tmp/dups"

# ---- cross-entry rules ---------------------------------------------------------------
# entries.json: [{file, id, inhouse, packages, extra, excl, ns}] of the entry files that
# passed L1 (non-string items are dropped: L7 reports them)
if [ -s "$tmp/entries.list" ]; then
  # file names may hold spaces: read the list line by line into the argument list
  set --
  while IFS= read -r _e; do set -- "$@" "$_e"; done <"$tmp/entries.list"
  jq -n '[inputs | {
      file: (input_filename | sub(".*/"; "")),
      id: (if (.sdk_id | type) == "string" then .sdk_id else "?" end),
      inhouse: (.in_house_wrapper == true),
      packages: [.packages | arrays | .[] | strings],
      extra: [.detection | objects | .extra_packages | arrays | .[] | strings],
      excl:  [.detection | objects | .exclude_packages | arrays | .[] | strings],
      ns:    [.detection | objects | .namespace_roots | arrays | .[] | strings] }]' "$@" >"$tmp/entries.json"
  set --
else
  echo '[]' >"$tmp/entries.json"
fi

CROSS_DEFS='
def under($a; $b): $a | startswith($b + ".");
def overlap($a; $b): $a == $b or under($a; $b) or under($b; $a);
def out(r; l; f; m): "\(r)\t\(l)\t\(f)\t\(m)";'

# L10 / L11 (entries only)
jq -r --slurpfile E "$tmp/entries.json" "$CROSS_DEFS"'
  $E[0] as $E
  # L10: in-house packages vs the packages of every other entry
  | ([$E[] | . as $e | .packages[] | {id: $e.id, file: $e.file, inhouse: $e.inhouse, p: .}]) as $P
  | ([$P[] | select(.inhouse) as $a | $P[] | select(.id != $a.id and overlap($a.p; .p))
      | out("L10"; "ERROR"; $a.file;
            "in-house package \($a.p) overlaps package \(.p) of \(.id)\(if .inhouse then " (in-house)" else "" end): in-house packages must be disjoint from every other package")]
     | unique[]),
  # L11: root A of x strictly contains root B of y, and x does not exclude B
    ([$E[] as $x | $E[] as $y | select($x.id != $y.id)
      | ($x.packages + $x.extra | unique)[] as $a | ($y.packages + $y.extra | unique)[] as $b
      | select(under($b; $a))
      | select(any($x.excl[]; . == $b or under($b; .)) | not)
      | out("L11"; "WARN"; $x.file; "root \($a) contains root \($b) of \($y.id), and \($x.id) does not exclude it (detection.exclude_packages)")]
     | unique[])
' -n >"$tmp/cross" 2>"$tmp/err" || report L10 ERROR "(registry)" "jq failed: $(head -n 1 "$tmp/err")"

# L13 / L15 (need _audit-shared.json), L14 (also needs detect-adwrapper.sh)
SHARED_FILE=$dir/_audit-shared.json
ADW=$(cd "$dir/.." 2>/dev/null && pwd)/scripts/detect-adwrapper.sh
if [ -f "$SHARED_FILE" ] && jq -e 'type == "object"' "$SHARED_FILE" >/dev/null 2>&1; then
  jq -r -n --slurpfile E "$tmp/entries.json" --slurpfile S "$SHARED_FILE" \
    --argjson cats "$CATEGORIES" --argjson tools "$TOOL_FLAGS" --argjson allow "$LIBROOT_ALLOW_JSON" "$CROSS_DEFS"'
    $E[0] as $E | $S[0] as $S | "_audit-shared.json" as $sf
    | ($E | map(.id)) as $ids
    # ---- L13
    | ($S.category_groups | if type == "object" then . else {} end) as $G
    | ($cats[] as $c | [$G | to_entries[] | select(.value | arrays | index([$c])) | .key] as $in
       | select(($in | length) != 1)
       | out("L13"; "ERROR"; $sf; "category \($c) is in \($in | length) group(s) of category_groups\(if ($in | length) > 1 then " (" + ($in | join(", ")) + ")" else "" end) (exactly one expected)")),
      ($G | to_entries[] | .key as $g | .value | arrays | .[] | select((. as $c | $cats | index([$c])) | not)
       | out("L13"; "ERROR"; $sf; "category_groups.\($g) holds \(tojson), not a category of the enum")),
      ($S.legacy_flags | objects | to_entries[] | .key as $t
       | if ($tools | has($t) | not) then out("L13"; "ERROR"; $sf; "legacy_flags.\($t): unknown tool (expected one of \($tools | keys | join(", ")))")
         else .value | arrays
           | (.[] | objects | select((.sdk_id | type) != "string" or (.sdk_id | IN($ids[]) | not))
              | out("L13"; "ERROR"; $sf; "legacy_flags.\($t): flag \(.flag | tojson) points to sdk_id \(.sdk_id | tojson), which is not a registry entry")),
             ([.[] | objects | .flag] | group_by(.)[] | select(length > 1)
              | out("L13"; "ERROR"; $sf; "legacy_flags.\($t): flag \(.[0] | tojson) appears \(length) times")),
             (.[] | objects | select(.flag | IN($tools[$t][]))
              | out("L13"; "ERROR"; $sf; "legacy_flags.\($t): flag \(.flag | tojson) is an aspect flag of \($t), not an SDK flag"))
         end),
      ($S.hints | arrays | . as $H
       | ([$H[] | objects | .id] | group_by(.)[] | select(length > 1)
          | out("L13"; "ERROR"; $sf; "hint id \(.[0] | tojson) appears \(length) times")),
         ($H | to_entries[] | .key as $i | .value | objects | "hint \(.id // $i | tojson)" as $n
          | (.tool as $tl | .flag as $fl
             | if ($tl | type) != "string" or ($tools | has($tl) | not) then out("L13"; "ERROR"; $sf; "\($n): tool \($tl | tojson) not in \($tools | keys | join(", "))")
               elif ($fl | type) != "string" or ($tools[$tl] | index([$fl]) | not) then
                 out("L13"; "ERROR"; $sf; "\($n): flag \($fl | tojson) is not an aspect flag of \($tl) (\($tools[$tl] | join(", ")))")
               else empty end),
            (if (.scope | IN("app_code", "manifest")) then empty else out("L13"; "ERROR"; $sf; "\($n): scope \(.scope | tojson) not in app_code, manifest") end),
            (if (.match | IN("method", "word", "literal", "exact")) | not then out("L13"; "ERROR"; $sf; "\($n): match \(.match | tojson) not in method, word, literal, exact")
             elif .match == "exact" and .scope != "manifest" then out("L13"; "ERROR"; $sf; "\($n): match exact is only for scope manifest (android:name values)")
             else empty end),
            (if .match == "word" then .tokens | arrays | .[] | strings | select(contains("_"))
               | out("L13"; "ERROR"; $sf; "\($n): token \(tojson) contains _ and uses match=word (use literal: _ is a word character)")
             else empty end))),
    # ---- L15
      (($S.library_roots | arrays | map(strings)) // []) as $LR
      | [$E[] | . as $e | (.packages + .extra)[] | {id: $e.id, r: .}] as $I
      | ($LR[] as $l
         | ([$I[] | select(.r == $l) | .id] | unique | select(length > 0)
            | out("L15"; "ERROR"; $sf; "library_root \($l) equals an identity root of \(join(", "))")),
           ([$I[] | select(under($l; .r))] | select(length > 0) | select($l | IN($allow[]) | not)
            | out("L15"; "ERROR"; $sf; "library_root \($l) is under the identity root \(.[0].r) of \(.[0].id) and is not in the L15 allowlist of lint-registry.sh"))),
        ($allow[] | . as $a
         | select(($a | IN($LR[]) | not) or ([$I[] | select(under($a; .r))] | length) == 0)
         | out("L15"; "WARN"; "lint-registry.sh"; "L15 allowlist item \($a) is no longer needed (not a library_root, or not under an identity root)"))
  ' >>"$tmp/cross" 2>"$tmp/err" || report L13 ERROR _audit-shared.json "jq failed: $(head -n 1 "$tmp/err")"

  if [ -f "$ADW" ]; then
    # the FROZEN tables (same extraction as tests/unit/t_network_roots.sh)
    for t in NETWORK_ROOTS COMMON_ROOTS; do
      awk -v name="$t" '
        !on && index($0, name "=\047") == 1 { on = 1; sub(/^[^\047]*\047/, "") }
        on { end = (index($0, "\047") > 0); sub(/\047.*$/, ""); if ($0 != "") print name "|" $0; if (end) exit }' "$ADW"
    done >"$tmp/tables.txt"
    jq -r -n --slurpfile E "$tmp/entries.json" --slurpfile S "$SHARED_FILE" --rawfile T "$tmp/tables.txt" '
      def slash: gsub("\\."; "/");
      def cov($a; $b): $a == $b or ($a | startswith($b + "/")) or ($b | startswith($a + "/"));
      $E[0] as $E
      | [$E[] | . as $e | (.packages + .extra + .ns)[] | {id: $e.id, r: slash}] as $R
      | (($S[0].library_roots | arrays | map(strings | slash)) // []) as $LR
      | $T | split("\n")[] | select(length > 0) | split("|") as [$t, $root, $lbl]
      | ([$R[] | select(cov(.r; $root)) | .id] | unique) as $own
      | if $t == "NETWORK_ROOTS" then
          (if ($own | length) == 0 then "L14\tINFO\tdetect-adwrapper.sh\tNETWORK_ROOTS \($root) (\($lbl)): no owning registry entry"
           elif ($own | length) > 1 then "L14\tINFO\tdetect-adwrapper.sh\tNETWORK_ROOTS \($root) (\($lbl)): shared by \($own | length) entries (\($own | join(", ")))"
           else empty end)
        elif ($own | length) == 0 and (any($LR[]; cov(.; $root)) | not) then
          "L14\tINFO\tdetect-adwrapper.sh\tCOMMON_ROOTS \($root): no owning registry entry and no library_root"
        else empty end
    ' >>"$tmp/cross" 2>"$tmp/err" || report L14 ERROR detect-adwrapper.sh "jq failed: $(head -n 1 "$tmp/err")"
  else
    skipped="$skipped L14"
  fi
else
  skipped="$skipped L13 L14 L15"
fi
while IFS="$(printf '\t')" read -r rule lvl f msg; do
  [ -n "$rule" ] && report "$rule" "$lvl" "$f" "$msg"
done <"$tmp/cross"

# SCHEMA (optional)
schema_state=skipped
if [ "$noschema" = 0 ] && [ -f "$dir/_schema.json" ] && command -v python3 >/dev/null 2>&1 &&
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

rules="L1-L15"
[ -z "$skipped" ] || rules="$rules (skipped:$skipped)"
echo "lint-registry: $nfiles file(s), $errors error(s), $warnings warning(s), $infos info(s) [rules $rules, schema: $schema_state] ($dir)"
[ "$errors" -eq 0 ]
