#!/usr/bin/env bash
# registry-query.sh -- the single reader of the SDK registry for shell tools
# (DESIGN 4). PowerShell twin: registry-query.ps1 (+ the function library
# registry-lib.ps1); rows/shared/packages output is byte-identical between the two.
#
# Usage:
#   registry-query.sh [--registry DIR] rows     [--lenient]
#   registry-query.sh [--registry DIR] shared
#   registry-query.sh [--registry DIR] packages [--lenient]
#   registry-query.sh check-jq
#   registry-query.sh version
#
# Registry directory: --registry DIR, else $SDK_REGISTRY_DIR, else <script dir>/../registry.
# Entry files are the *.json files whose name does not start with '_';
# _audit-shared.json holds the cross-SDK audit knowledge.
#
# Verbs (UTF-8, LF, no header, one final LF when there are rows; values escaped like
# jq @tsv; an empty or null value is printed as '-'):
#   rows      sdk_id<TAB>category<TAB>field<TAB>value, entries in ordinal sdk_id order;
#             fields in this order: file display_name vendor group in_house_wrapper
#             has_targets package extra_package exclude_package namespace_root
#             adapter_package marker_class target_api ("FQCN method entry_point|ad_operation")
#             api ("FQCN method role") manifest_component manifest_name domain
#             id_prefix ("prefix label"). group = ads|trackers|consent|other.
#   shared    kind<TAB>key<TAB>value from _audit-shared.json, in file order. Kinds:
#             category_group tool_group section_separator legacy_flag role_label
#             format_token library_root hint_meta hint_title hint_token.
#   packages  sdk_id<TAB>in_house(true|false)<TAB>package: only .packages[] (what
#             detect-adwrapper reads). Uses jq when jq >= 1.6 is available, otherwise
#             a POSIX awk parser that reads only sdk_id, in_house_wrapper and packages.
#   check-jq  exit 0 when jq >= 1.6 is available, else exit 2 + INSTALL_REQUIRED:jq.
#   version   registry-query<TAB>1<TAB><backend> (jq-<version> | awk).
#
# Integrity (strict, the default): an unreadable file, a BOM, an empty file, invalid
# JSON, more than one JSON document, a root that is not an object, keys that differ
# only by case, a missing or duplicate sdk_id, or targets: null is an error:
#   registry-query: ERROR <file>: <message>                        -> exit 1
# --lenient skips such entry files instead:
#   registry-query: WARN skipping <file>: <message>                -> exit 0
# Exit: 0 ok; 1 usage error, missing directory, no valid entry, integrity error;
#       2 rows/shared/check-jq need jq >= 1.6 (stdout INSTALL_REQUIRED:jq).
# jq is looked up on PATH with ~/.local/bin (where `install-dep.sh jq` puts it) prepended
# when that directory exists and is not on PATH yet, like the installer and the checkers.
# Portability: bash 3.2, POSIX awk, jq >= 1.6 (optional for `packages`).
set -uo pipefail
export LC_ALL=C

# Same jq resolution as install-dep.sh / check-deps.sh / check-neutralize-deps.sh: the
# static jq of `install-dep.sh jq` lives in ~/.local/bin, which may be missing from the
# caller's PATH (a session started before the directory existed).
if [ -n "${HOME:-}" ] && [ -d "$HOME/.local/bin" ]; then
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH"; export PATH ;; esac
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
JQ_PROG=$SCRIPT_DIR/registry-query.jq
TAB=$(printf '\t')
NL='
'
SHARED_NAME=_audit-shared.json

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
die_usage() { echo "registry-query: $1" >&2; echo "Run 'registry-query.sh --help' for usage." >&2; exit 1; }
err() { printf 'registry-query: ERROR %s\n' "$1" >&2; }

registry=""
verb=""
lenient=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --registry) [ $# -ge 2 ] || die_usage "--registry requires a directory"
                registry=$2; shift ;;
    --registry=*) registry=${1#--registry=} ;;
    --lenient) lenient=1 ;;
    -*) die_usage "unknown option: $1" ;;
    *) [ -z "$verb" ] || die_usage "unexpected argument: $1"
       verb=$1 ;;
  esac
  shift
done
[ -n "$verb" ] || die_usage "missing verb (rows | shared | packages | check-jq | version)"
case "$verb" in rows|shared|packages|check-jq|version) ;; *) die_usage "unknown verb: $verb" ;; esac

have_jq16() {
  command -v jq >/dev/null 2>&1 || return 1
  [ "$(jq -nr '[limit(1;1,2)] | IN(.[]; 1) | tostring' 2>/dev/null)" = true ]
}
install_required() {
  plugin_root=$(cd "$SCRIPT_DIR/../../.." && pwd)
  echo "INSTALL_REQUIRED:jq"
  echo "Run: bash $plugin_root/skills/android-reverse-engineering/scripts/install-dep.sh jq" >&2
  exit 2
}

case "$verb" in
  version)
    if have_jq16; then backend=$(jq --version 2>/dev/null); else backend=awk; fi
    printf 'registry-query\t1\t%s\n' "$backend"
    exit 0 ;;
  check-jq)
    have_jq16 || install_required
    echo "[OK] $(jq --version 2>/dev/null) detected (>= 1.6)"
    exit 0 ;;
esac

if [ -z "$registry" ]; then
  if [ -n "${SDK_REGISTRY_DIR:-}" ]; then registry=$SDK_REGISTRY_DIR; else registry=$SCRIPT_DIR/../registry; fi
fi
while [ "$registry" != / ] && [ "${registry%/}" != "$registry" ]; do registry=${registry%/}; done
[ -d "$registry" ] || { err "registry directory not found: $registry"; exit 1; }

use_jq=1
have_jq16 || use_jq=0
if [ "$use_jq" = 0 ] && [ "$verb" != packages ]; then install_required; fi

# ---- inputs -------------------------------------------------------------------------
# entry files in byte order (LC_ALL=C glob), `_*` and non-regular files skipped (the
# ps1 twin lists files only); unreadable ones are kept in `files` (they get the
# per-file "unreadable file" diagnosis, in file order) and listed in `unreadable`
files=()
readable=()
unreadable=""
for f in "$registry"/*.json; do
  [ -f "$f" ] || continue
  case "${f##*/}" in _*) continue ;; esac
  files+=("$f")
  if [ -r "$f" ]; then readable+=("$f"); else unreadable="$unreadable$f$NL"; fi
done
shared_file=""
if [ "$verb" = rows ] || [ "$verb" = shared ]; then
  shared_file=$registry/$SHARED_NAME
  [ -f "$shared_file" ] || { err "$SHARED_NAME: file not found in $registry"; exit 1; }
fi
if [ "$verb" != shared ] && [ "${#files[@]}" -eq 0 ]; then
  err "no registry entries in $registry"; exit 1
fi

# files that start with a UTF-8 BOM (one awk for all files; jq would accept a BOM
# on the first file only, PowerShell strips it silently: both twins reject it)
# (an unreadable file would stop gawk/mawk: only readable files are scanned)
if [ "$verb" = shared ]; then files=(); readable=(); unreadable=""; fi   # shared reads only _audit-shared.json
shared_readable=""
if [ -n "$shared_file" ] && [ -r "$shared_file" ]; then shared_readable=$shared_file; fi
bom_list=$(awk 'FNR == 1 && substr($0, 1, 3) == "\357\273\277" { print FILENAME }' \
  ${shared_readable:+"$shared_readable"} ${readable[@]+"${readable[@]}"} 2>/dev/null </dev/null)
is_bom() { case "$NL$bom_list$NL" in *"$NL$1$NL"*) return 0 ;; esac; return 1; }
is_unreadable() { case "$NL$unreadable" in *"$NL$1$NL"*) return 0 ;; esac; return 1; }

run_jq() { # run_jq <verb> <nfiles> <needid> <file>... -> stdout, jq's exit status
  _v=$1 _n=$2 _id=$3; shift 3
  jq -rn --arg verb "$_v" --argjson nfiles "$_n" --argjson needid "$_id" -f "$JQ_PROG" "$@"
}
print_out() { [ -z "$1" ] || printf '%s\n' "$1"; }

# ---- awk fallback for `packages` (no jq, or jq < 1.6: DESIGN 4.4) --------------------
# Reads only: the first "sdk_id": "<v>", the presence of "in_house_wrapper": true, and
# the strings of the "packages" array whose key starts a line (one or several lines).
# Output: E<TAB>file<TAB>message | R<TAB>sdk_id<TAB>seq<TAB>in_house<TAB>package | N<TAB>count
# awk reads only the readable files; _RQ_ALL (every entry file, in order) drives the
# END loop so an unreadable file gets its E line in file order.
packages_awk() {
  _all=$(printf '%s\n' "${files[@]}")
  _RQ_BOM=$bom_list _RQ_UNR=$unreadable _RQ_ALL=$_all awk '
    function basename(p) { sub(/.*\//, "", p); return p }
    function pkscan(s,    q, b, e) {
      # state 1: waiting for "["; state 2: inside the array; state 3: done
      while (s != "") {
        if (pk[FILENAME] == 1) {
          sub(/^[ \t\r]+/, "", s)
          if (s == "") return
          if (substr(s, 1, 1) != "[") { pk[FILENAME] = 3; return }
          pk[FILENAME] = 2; s = substr(s, 2)
        } else if (pk[FILENAME] == 2) {
          q = index(s, "\""); b = index(s, "]")
          if (b > 0 && (q == 0 || b < q)) { pk[FILENAME] = 3; return }
          if (q == 0) return
          s = substr(s, q + 1)
          e = index(s, "\"")
          if (e == 0) { pk[FILENAME] = 3; return }
          npk[FILENAME]++
          pkv[FILENAME, npk[FILENAME]] = substr(s, 1, e - 1)
          s = substr(s, e + 1)
        } else return
      }
    }
    BEGIN {
      nb = split(ENVIRON["_RQ_BOM"], tmp, "\n")
      for (i = 1; i <= nb; i++) if (tmp[i] != "") bom[tmp[i]] = 1
      nb = split(ENVIRON["_RQ_UNR"], tmp, "\n")
      for (i = 1; i <= nb; i++) if (tmp[i] != "") unr[tmp[i]] = 1
    }
    {
      seen[FILENAME] = 1
      line = $0
      if (line ~ /[^ \t\r]/) nonblank[FILENAME] = 1
      if (!(FILENAME in sdk) && match(line, /"sdk_id"[ \t]*:[ \t]*"[^"]*"/)) {
        v = substr(line, RSTART, RLENGTH)
        sub(/^"sdk_id"[ \t]*:[ \t]*"/, "", v); sub(/"$/, "", v)
        sdk[FILENAME] = v
      }
      if (line ~ /"in_house_wrapper"[ \t]*:[ \t]*true/) inhouse[FILENAME] = 1
      if (pk[FILENAME] == 0 && line ~ /^[ \t]*"packages"[ \t]*:/) {
        pk[FILENAME] = 1
        sub(/^[ \t]*"packages"[ \t]*:/, "", line)
        pkscan(line)
      } else if (pk[FILENAME] == 1 || pk[FILENAME] == 2) pkscan(line)
    }
    END {
      nok = 0; seq = 0
      nall = split(ENVIRON["_RQ_ALL"], all, "\n")
      for (i = 1; i <= nall; i++) {
        f = all[i]; if (f == "") continue
        b = basename(f)
        if (f in unr) { print "E\t" b "\tunreadable file"; continue }
        if (f in bom) { print "E\t" b "\tBOM not allowed"; continue }
        if (!(f in nonblank)) { print "E\t" b "\tempty file"; continue }
        if (!(f in sdk) || sdk[f] == "") { print "E\t" b "\tsdk_id missing or not a string"; continue }
        id = sdk[f]
        if (id in owner) { print "E\t" b "\tduplicate sdk_id " id " (also in " owner[id] ")"; continue }
        owner[id] = b; nok++
        ih = (f in inhouse) ? "true" : "false"
        for (j = 1; j <= npk[f]; j++) {
          p = pkv[f, j]; if (p == "") p = "-"
          seq++
          print "R\t" id "\t" seq "\t" ih "\t" p
        }
      }
      print "N\t" nok
    }' ${readable[@]+"${readable[@]}"} </dev/null
}

if [ "$use_jq" = 0 ]; then
  # only `packages` gets here
  raw=$(packages_awk) || { err "awk failed while reading $registry"; exit 1; }
  errs=$(printf '%s\n' "$raw" | awk -F '\t' '$1 == "E" { print $2 ": " $3 }')
  nok=$(printf '%s\n' "$raw" | awk -F '\t' '$1 == "N" { print $2 }')
  if [ -n "$errs" ]; then
    if [ "$lenient" = 1 ]; then
      printf '%s\n' "$errs" | sed 's/^/registry-query: WARN skipping /' >&2
    else
      printf '%s\n' "$errs" | sed 's/^/registry-query: ERROR /' >&2
      exit 1
    fi
  fi
  [ "${nok:-0}" -gt 0 ] || { err "no valid entries in $registry"; exit 1; }
  out=$(printf '%s\n' "$raw" | awk -F '\t' '$1 == "R"' | sort -t "$TAB" -k2,2 -k3,3n |
        awk -F '\t' '{ print $2 "\t" $4 "\t" $5 }')
  print_out "$out"
  exit 0
fi

# ---- jq: fast path (one process), then per-file diagnosis ---------------------------
nshared=0
[ -z "$shared_file" ] || nshared=1
if [ -z "$bom_list" ] && [ -z "$unreadable" ] && { [ -z "$shared_file" ] || [ -n "$shared_readable" ]; }; then
  if [ "$verb" = shared ]; then
    out=$(run_jq shared 1 false "$shared_file" 2>/dev/null) && { print_out "$out"; exit 0; }
  else
    out=$(run_jq "$verb" $(( ${#files[@]} + nshared )) true ${shared_file:+"$shared_file"} "${files[@]}" 2>/dev/null) &&
      { print_out "$out"; exit 0; }
  fi
fi

check_file() { # check_file <file> <needid> -> chk_status (OK|ERR), chk_val (sdk_id | message)
  if is_unreadable "$1" || [ ! -r "$1" ]; then chk_status=ERR; chk_val="unreadable file"; return 0; fi
  if is_bom "$1"; then chk_status=ERR; chk_val="BOM not allowed"; return 0; fi
  if ! _res=$(run_jq check -1 "$2" "$1" 2>/dev/null) || [ -z "$_res" ]; then
    chk_status=ERR; chk_val="invalid JSON"; return 0
  fi
  chk_status=${_res%%"$TAB"*}; chk_val=${_res#*"$TAB"}
}

# the shared file is never skipped: an error in it is fatal, --lenient or not
if [ -n "$shared_file" ]; then
  check_file "$shared_file" false
  if [ "$chk_status" != OK ]; then err "$SHARED_NAME: $chk_val"; exit 1; fi
fi
if [ "$verb" = shared ]; then err "jq failed on $shared_file"; exit 1; fi

good=()
msgs=""
seen_ids=""   # NL-separated "sdk_id<TAB>file"
for f in "${files[@]}"; do
  b=${f##*/}
  check_file "$f" true
  if [ "$chk_status" = OK ]; then
    owner=$(printf '%s\n' "$seen_ids" | _RQ_ID=$chk_val awk -F '\t' '$1 == ENVIRON["_RQ_ID"] { print $2; exit }')
    if [ -n "$owner" ]; then
      msgs="$msgs$b: duplicate sdk_id $chk_val (also in $owner)$NL"; continue
    fi
    seen_ids="$seen_ids$chk_val$TAB$b$NL"
    good+=("$f")
  else
    msgs="$msgs$b: $chk_val$NL"
  fi
done
if [ -n "$msgs" ]; then
  if [ "$lenient" = 1 ]; then
    printf '%s' "$msgs" | sed 's/^/registry-query: WARN skipping /' >&2
  else
    printf '%s' "$msgs" | sed 's/^/registry-query: ERROR /' >&2
    exit 1
  fi
fi
[ "${#good[@]}" -gt 0 ] || { err "no valid entries in $registry"; exit 1; }
if out=$(run_jq "$verb" $(( ${#good[@]} + nshared )) true ${shared_file:+"$shared_file"} "${good[@]}" 2>/dev/null); then
  print_out "$out"; exit 0
fi
err "jq failed while reading $registry"
exit 1
