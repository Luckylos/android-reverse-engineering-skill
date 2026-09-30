# registry-query.jq -- jq program behind registry-query.sh (DESIGN 4.2-4.3).
# Invoked as:
#   jq -rn --arg verb V --argjson nfiles N --argjson needid B -f registry-query.jq FILE...
#   verb rows      FILES = _audit-shared.json + the entry files; N = number of files
#   verb packages  FILES = the entry files
#   verb shared    FILES = _audit-shared.json
#   verb check     one file; prints "OK<TAB>sdk_id" or "ERR<TAB>message" (integrity
#                  diagnosis, needid = the file must be an SDK entry)
# rows/packages/shared exit 5 (error) on any integrity problem (a file with 0 or 2+
# documents, root not an object, case-colliding keys, missing/duplicate sdk_id,
# targets: null): registry-query.sh then runs `check` on each file to name the culprit.
# Portability: jq >= 1.6. No regex (test/match/capture/sub/gsub need Oniguruma), no
# `if` without `else`, no pick/abs/trim/toarray/scan/2/debug/1/limit(0;...), no
# builtin stderr, no --raw-output0. Messages are printed by the shell.

def nz: if . == null or . == "" then "-" else tostring end;
def arr(f): f | if type == "array" then .[] else empty end;
def obj(f): f | if type == "object" then . else {} end;
def objs: if type == "object" then . else empty end;
def oents: if type == "object" then to_entries[] else empty end;
def base: split("/") | last;

# keys that differ only by ASCII case, at any level (PS 5.1 ConvertFrom-Json rejects them)
def case_collisions:
  [.. | objects | keys_unsorted | map(ascii_downcase) | group_by(.)[] | select(length > 1) | .[0]];

# first integrity problem of one parsed document, or null
def problem($needid):
  if type != "object" then "root is not an object"
  else (case_collisions) as $cc
  | if ($cc | length) > 0 then "case-colliding keys: \($cc[0])"
    elif ($needid | not) then null
    elif (.sdk_id | type) != "string" or .sdk_id == "" then "sdk_id missing or not a string"
    elif has("targets") and .targets == null then "targets is null"
    else null end
  end;

def group_of($cg):
  . as $c
  | [$cg | oents | select(.value | type == "array" and any(.[]; . == $c)) | .key]
  | if length > 0 then .[0] else "other" end;

def row($id; $cat; $field; $val): [$id, $cat, $field, ($val | nz)] | @tsv;

# rows: sdk_id<TAB>category<TAB>field<TAB>value, fixed field order (DESIGN 4.2)
def entry_rows($file; $cg):
  (.sdk_id | nz) as $id
  | (.category | nz) as $cat
  | obj(.targets) as $t
  | obj(.detection) as $d
  | row($id; $cat; "file"; $file),
    row($id; $cat; "display_name"; .display_name),
    row($id; $cat; "vendor"; .vendor),
    row($id; $cat; "group"; (.category | group_of($cg))),
    row($id; $cat; "in_house_wrapper"; (.in_house_wrapper == true | tostring)),
    row($id; $cat; "has_targets"; (has("targets") | tostring)),
    (arr(.packages) | row($id; $cat; "package"; .)),
    (arr($d.extra_packages) | row($id; $cat; "extra_package"; .)),
    (arr($d.exclude_packages) | row($id; $cat; "exclude_package"; .)),
    (arr($d.namespace_roots) | row($id; $cat; "namespace_root"; .)),
    (arr($d.adapter_packages) | row($id; $cat; "adapter_package"; .)),
    (arr($d.marker_classes) | row($id; $cat; "marker_class"; .)),
    (arr($t.entry_points) | objs | (.class | nz) as $c
       | arr(.methods) | objs | row($id; $cat; "target_api"; "\($c) \(.name | nz) entry_point")),
    (arr($t.ad_operations) | objs | (.class | nz) as $c
       | arr(.methods) | objs | row($id; $cat; "target_api"; "\($c) \(.name | nz) ad_operation")),
    (arr($d.apis) | objs | (.class | nz) as $c | (.role | nz) as $r
       | arr(.methods) | row($id; $cat; "api"; "\($c) \(nz) \($r)")),
    (arr(.manifest_components) | objs | row($id; $cat; "manifest_component"; .class)),
    (arr($d.manifest_names) | row($id; $cat; "manifest_name"; .)),
    (arr($d.domains) | row($id; $cat; "domain"; .)),
    (arr($d.id_prefixes) | objs | row($id; $cat; "id_prefix"; "\(.prefix | nz) \(.label | nz)"));

# packages: sdk_id<TAB>in_house(true|false)<TAB>package_dotted (only .packages[])
def entry_packages:
  (.sdk_id | nz) as $id
  | (.in_house_wrapper == true | tostring) as $ih
  | arr(.packages) | [$id, $ih, nz] | @tsv;

# shared: kind<TAB>key<TAB>value from _audit-shared.json, in file order
def srow($kind; $key; $val): [$kind, ($key | nz), ($val | nz)] | @tsv;
def fpair: if type == "array" then "\(.[0] | nz) \(.[1] | nz)" else nz end;
def shared_rows:
  oents | .key as $k | .value as $v
  | if $k == "category_groups" then ($v | oents | .key as $g | arr(.value) | srow("category_group"; $g; .))
    elif $k == "tool_groups" then ($v | oents | .key as $g | arr(.value) | srow("tool_group"; $g; .))
    elif $k == "section_separator" then srow("section_separator"; "-"; $v)
    elif $k == "legacy_flags" then
      ($v | oents | .key as $tool | arr(.value) | objs
       | srow("legacy_flag"; $tool; "\(.flag | nz) \(.sdk_id | nz) \(.label | nz) \(.section_prefix | nz)"))
    elif $k == "role_labels" then ($v | oents | srow("role_label"; .key; .value))
    elif $k == "format_by_class" then (arr($v) | srow("format_token"; "by_class"; fpair))
    elif $k == "format_by_class_token" then (arr($v) | srow("format_token"; "by_class_token"; fpair))
    elif $k == "format_by_method_token" then (arr($v) | srow("format_token"; "by_method_token"; fpair))
    elif $k == "format_none" then (arr($v) | srow("format_token"; "none"; .))
    elif $k == "library_roots" then (arr($v) | srow("library_root"; "-"; .))
    elif $k == "hints" then
      (arr($v) | objs | (.id | nz) as $id
       | srow("hint_meta"; $id; "\($id) \(.tool | nz) \(.flag | nz) \(.scope | nz) \(.match | nz)"),
         srow("hint_title"; $id; .title),
         (arr(.tokens) | srow("hint_token"; $id; .)))
    else empty end;

if $verb == "check" then
  [inputs] as $docs
  | if ($docs | length) == 0 then "ERR\tempty file"
    elif ($docs | length) > 1 then "ERR\tmore than one JSON document"
    else ($docs[0] | problem($needid)) as $p
      | if $p != null then ["ERR", $p] | @tsv
        elif $needid then ["OK", $docs[0].sdk_id] | @tsv
        else "OK\t-" end
    end
else
  [inputs | {f: (input_filename | base), d: .}] as $all
  | [$all[] | select(.f | startswith("_") | not)] as $ents
  | ([$all[] | select(.f == "_audit-shared.json") | .d] | if length > 0 then .[0] else {} end) as $shared
  | if ($all | length) != $nfiles
       or ([$all[].f] | unique | length) != ($all | length)
       or any($all[]; (.f | startswith("_") | not) as $n | .d | problem($n) != null)
       or ([$ents[].d.sdk_id] | unique | length) != ($ents | length)
    then error("registry-query: integrity check failed")
    else . end
  | if $verb == "rows" then
      obj($shared.category_groups) as $cg
      | $ents | sort_by(.d.sdk_id) | .[] | .f as $f | .d | entry_rows($f; $cg)
    elif $verb == "packages" then
      $ents | sort_by(.d.sdk_id) | .[] | .d | entry_packages
    elif $verb == "shared" then
      $shared | shared_rows
    else error("registry-query: unknown verb \($verb)") end
end
