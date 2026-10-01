#!/usr/bin/env bash
# marker-verify.sh -- T-MARKER (DESIGN 3.1 R4, 9.2): every detection.marker_classes item
# of the registry is a real class: its file exists in at least one corpus app where the
# ground truth has that SDK, or the marker is in tests/corpus/marker-allowlist.tsv with a
# reason.
#   ground truth  $ARE_GROUND_TRUTH (default $ARE_WORKSPACE/registry-unification/
#                 ground-truth.json): an array of {app, decoded_dir, sdks[]}. The app has
#                 SDK <id> when an sdks[] item has registry_sdk_id <id> (a string or an
#                 array), or when an item without registry_sdk_id (an SDK with no entry when
#                 the ground truth was built, e.g. flurry) lists a package equal to an
#                 identity root of <id> (packages + detection.extra_packages), under one,
#                 or above one.
#   corpus tree   per app, the fresh pristine decode $ARE_PRISTINE/<app> (DESIGN Q4); when
#                 it is missing, the apktool decode $ARE_CORPUS/<app>-decoded, else the
#                 ground truth's decoded_dir. A marker a.b.C is present when
#                 smali/a/b/C.smali or smali_classesN/a/b/C.smali exists (smali_assets is
#                 not app DEX code and is ignored).
# Allowlist: $ARE_MARKER_ALLOWLIST (default tests/corpus/marker-allowlist.tsv).
# Also checked: allowlist rows are well formed (sdk_id<TAB>class<TAB>reason) and name a
# declared marker. An allowlisted marker that the corpus now verifies is reported as a
# note (the row can go). One informative line per marker: present in N of M ground-truth
# apps.
# SKIP when the ground truth or every corpus tree is missing, or when no entry declares
# marker_classes; a marker whose ground-truth apps all lack a corpus tree makes the
# test SKIP too (so `--expect-pass` reports it), unless another marker fails.
# requires: cmd: have_jq16
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
export LC_ALL=C

GT=${ARE_GROUND_TRUTH:-$ARE_WORKSPACE/registry-unification/ground-truth.json}
ALLOW=${ARE_MARKER_ALLOWLIST:-$TESTS_DIR/corpus/marker-allowlist.tsv}
[ -f "$GT" ] || skip "ground truth not found: $GT (set ARE_GROUND_TRUTH)"
[ -d "$REG" ] || die "registry not found: $REG"
mktemp_dir tmp

# ---- registry: sdk_id <TAB> marker <TAB> identity roots (space-separated) ---------------
set -- "$REG"/[!_]*.json
jq -r '
  select((.detection.marker_classes // []) | length > 0)
  | .sdk_id as $id
  | ([(.packages // [])[], (.detection.extra_packages // [])[]] | join(" ")) as $roots
  | .detection.marker_classes[] | [$id, ., $roots] | join("\t")' "$@" >"$tmp/markers" ||
  die "jq failed on the registry"
[ -s "$tmp/markers" ] || skip "no entry declares detection.marker_classes"

# ---- ground truth: app <TAB> decoded_dir <TAB> id|pkg <TAB> value ------------------------
jq -r '
  .[] | .app as $a | (.decoded_dir // "-") as $d
  | .sdks[]
  | if .registry_sdk_id == null then (.packages // [])[] | [$a, $d, "pkg", .]
    else (.registry_sdk_id | if type == "array" then .[] else . end) | [$a, $d, "id", .]
    end
  | join("\t")' "$GT" >"$tmp/gt" || die "cannot read the ground truth: $GT"
[ -s "$tmp/gt" ] || die "empty ground truth: $GT"

# ---- candidate rows: sdk_id <TAB> marker <TAB> app <TAB> decoded_dir --------------------
# overlap(p, r): p == r, p under r, or r under p (dotted names).
awk -F '\t' '
  function overlap(p, r) {
    return p == r || index(p, r ".") == 1 || index(r, p ".") == 1
  }
  NR == FNR { n++; app[n] = $1; dir[n] = $2; kind[n] = $3; val[n] = $4; next }
  {
    nr = split($3, roots, " "); found = 0
    for (i = 1; i <= n; i++) {
      if ((FNR SUBSEP app[i]) in seen) continue
      hit = 0
      if (kind[i] == "id") hit = (val[i] == $1)
      else for (k = 1; k <= nr; k++) if (overlap(val[i], roots[k])) { hit = 1; break }
      if (hit) { seen[FNR, app[i]] = 1; found++; print $1 "\t" $2 "\t" app[i] "\t" dir[i] }
    }
    if (found == 0) print $1 "\t" $2 "\t-\t-"
  }' "$tmp/gt" "$tmp/markers" >"$tmp/cand" || die "awk failed"

# tree_of <app> <gt-decoded-dir>: the corpus tree used for <app> (empty when none)
tree_of() {
  if [ -d "$ARE_PRISTINE/$1" ]; then echo "$ARE_PRISTINE/$1"
  elif [ -d "$ARE_CORPUS/$1-decoded" ]; then echo "$ARE_CORPUS/$1-decoded"
  elif [ "$2" != - ] && [ -d "$2" ]; then echo "$2"
  fi
}
# has_class <tree> <slash-path>: the class file is in the main DEX smali dirs
has_class() {
  for _d in "$1"/smali "$1"/smali_classes*; do
    [ -f "$_d/$2.smali" ] && return 0
  done
  return 1
}

any_tree=0
for a in $(cut -f1 "$tmp/gt" | sort -u); do
  d=$(awk -F '\t' -v a="$a" '$1 == a { print $2; exit }' "$tmp/gt")
  [ -n "$(tree_of "$a" "$d")" ] && any_tree=1
done
[ "$any_tree" = 1 ] || skip "no corpus tree for any ground-truth app (ARE_PRISTINE=$ARE_PRISTINE, ARE_CORPUS=$ARE_CORPUS)"

# ---- allowlist ---------------------------------------------------------------------------
: >"$tmp/allow"
if [ -f "$ALLOW" ]; then
  awk -F '\t' '/^#/ || /^[ \t]*$/ { next }
    { print FNR "\t" NF "\t" $1 "\t" $2 "\t" $3 }' "$ALLOW" >"$tmp/allow.raw"
  while IFS="$(printf '\t')" read -r ln nf id cls why; do
    _T_CHECKS=$((_T_CHECKS + 1))
    if [ "$nf" != 3 ] || [ -z "$id" ] || [ -z "$cls" ] || [ -z "$why" ]; then
      fail_check "marker-allowlist.tsv:$ln: expected sdk_id<TAB>class<TAB>reason"; continue
    fi
    _T_CHECKS=$((_T_CHECKS + 1))
    if awk -F '\t' -v i="$id" -v c="$cls" '$1 == i && $2 == c { f = 1 } END { exit !f }' "$tmp/markers"; then
      printf '%s\t%s\n' "$id" "$cls" >>"$tmp/allow"
    else
      fail_check "marker-allowlist.tsv:$ln: $id $cls is not a declared marker_classes item (stale row)"
    fi
  done <"$tmp/allow.raw"
fi
allowed() { awk -F '\t' -v i="$1" -v c="$2" '$1 == i && $2 == c { f = 1 } END { exit !f }' "$tmp/allow"; }

# ---- verify ------------------------------------------------------------------------------
unverifiable=""
while IFS="$(printf '\t')" read -r id cls; do
  path=$(printf '%s' "$cls" | tr . /)
  apps=$(awk -F '\t' -v i="$id" -v c="$cls" '$1 == i && $2 == c && $3 != "-" { print $3 "\t" $4 }' "$tmp/cand")
  total=0; trees=0; present=""; absent=""
  if [ -n "$apps" ]; then
    while IFS="$(printf '\t')" read -r a d; do
      total=$((total + 1))
      t=$(tree_of "$a" "$d")
      [ -n "$t" ] || continue
      trees=$((trees + 1))
      if has_class "$t" "$path"; then present="$present $a"; else absent="$absent $a"; fi
    done <<EOF
$apps
EOF
  fi
  n=$(echo $present | wc -w | tr -d ' ')
  echo "$id $cls: present in $n of $trees ground-truth app(s) with a corpus tree (of $total)${present:+ [${present# }]}${absent:+, absent [${absent# }]}"
  _T_CHECKS=$((_T_CHECKS + 1))
  if [ "$n" -gt 0 ]; then
    pass_check "$id $cls verified"
    allowed "$id" "$cls" && echo "  note: $id $cls is verified by the corpus; its marker-allowlist.tsv row is no longer needed"
  elif allowed "$id" "$cls"; then
    pass_check "$id $cls allowlisted"
  elif [ "$total" -eq 0 ]; then
    fail_check "$id $cls: the ground truth has $id in no app and the marker is not in marker-allowlist.tsv"
  elif [ "$trees" -eq 0 ]; then
    unverifiable="$unverifiable $id:$cls"
  else
    fail_check "$id $cls: class file not found in any ground-truth app that has $id (and not in marker-allowlist.tsv)"
  fi
done <<EOF
$(cut -f1,2 "$tmp/markers")
EOF

if [ -n "$unverifiable" ] && [ "$_T_FAILS" -eq 0 ]; then
  skip "no corpus tree for the ground-truth apps of:$unverifiable"
fi
t_done
