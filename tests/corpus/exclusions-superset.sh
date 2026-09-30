#!/usr/bin/env bash
# exclusions-superset.sh -- invariant I11 (DESIGN 6, 9.1): the exclusions of
# detect-adwrapper effectively cover those of the legacy script, in every registry-reading
# mode (jq >= 1.6, no jq = awk fallback, jq 1.5 = awk fallback).
#   old = legacy detect-adwrapper.sh of $ARE_BASE_COMMIT (grep of every dotted string of
#         each registry file) run on the registry of $ARE_BASE_COMMIT, patched at test time
#         to print its EXCL set and in-house map ("today's" exclusions, fixed input);
#   new = detect-adwrapper.sh --dump-exclusions (.packages only) on the registry of this
#         checkout.
# Checks: every old EXCL entry equals a new EXCL entry or sits under one; the only old
# entries without a literal match are the known ones below (the class name
# ...consent_sdk.zzj, covered by COMMON com/google); every old in-house key is covered by
# a new in-house key of the same sdk_id; jq / nojq / jq15 dumps are identical. Then, on
# the 8 apps of the apktool corpus (when present), the whole stdout/stderr of
# detect-adwrapper.sh in the nojq and jq15 modes is byte-identical to the frozen baseline
# G ($ARE_GOLD/before/adwrapper/<app>) -- the golden suite covers the jq mode.
# requires: NS/detect-adwrapper.sh NS/registry-query.sh
# requires: cmd: grep -q -- --dump-exclusions "$NS/detect-adwrapper.sh"
# requires: cmd: have_jq16
# requires: cmd: git -C "$REPO" cat-file -e "$ARE_BASE_COMMIT^{commit}"
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
export LC_ALL=C

KNOWN_NONLITERAL="com/google/android/gms/internal/consent_sdk/zzj"
DW=$NS/detect-adwrapper.sh
REL=plugins/android-reverse-engineering/skills/sdk-neutralizer
mktemp_dir tmp

# ---- old: legacy script + legacy registry, patched to dump ------------------------------
git -C "$REPO" archive "$ARE_BASE_COMMIT" "$REL/registry" "$REL/scripts/detect-adwrapper.sh" | tar -x -C "$tmp" ||
  die "cannot read $REL from $ARE_BASE_COMMIT"
LEG=$tmp/$REL/scripts/detect-adwrapper.sh
anchor="EXCL=\$(printf '%s\\n' \"\$EXCL\" | LC_ALL=C sort -u | grep -v '^\$' || true)"
assert_eq 1 "$(grep -cxF "$anchor" "$LEG")" "legacy script has the EXCL anchor line"
_ARE_ANCHOR=$anchor awk '
  { print }
  $0 == ENVIRON["_ARE_ANCHOR"] {
    print "printf \047%s\\n\047 \"$EXCL\" | awk \047NF { print \"EXCL:\" $0 }\047"
    print "printf \047%s\\n\047 \"$INHOUSE_MAP\" | awk \047NF { print \"INHOUSE:\" $0 }\047"
    print "exit 0"
  }' "$LEG" >"$tmp/legacy-dump.sh"
mkdir -p "$tmp/dummy/smali"; echo '<manifest package="x.y"/>' >"$tmp/dummy/AndroidManifest.xml"
bash "$tmp/legacy-dump.sh" "$tmp/dummy" --registry "$tmp/$REL/registry" >"$tmp/old.dump" 2>"$tmp/old.err"
assert_eq 0 "$?" "legacy dump: exit 0"
assert_true "legacy dump has EXCL lines" grep -q '^EXCL:' "$tmp/old.dump"
sed -n 's/^EXCL://p' "$tmp/old.dump" >"$tmp/old.excl"
sed -n 's/^INHOUSE://p' "$tmp/old.dump" | sort -u >"$tmp/old.inhouse"
echo "old: $(wc -l <"$tmp/old.excl" | tr -d ' ') EXCL, $(wc -l <"$tmp/old.inhouse" | tr -d ' ') in-house keys"

# covered <old-list> <new-list> -> prints "<entry><TAB>literal|under|NONE"
covered() {
  awk -F '|' 'NR == FNR { if ($0 != "") nw[$0] = 1; next }
    $0 == "" { next }
    { o = $0
      if (o in nw) { print o "\tliteral"; next }
      s = o; how = "NONE"
      while ((i = match(s, /\/[^\/]*$/)) > 0) { s = substr(s, 1, i - 1); if (s in nw) { how = "under"; break } }
      print o "\t" how }' "$2" "$1"
}

# ---- new: every mode ---------------------------------------------------------------
for mode in jq nojq jq15; do
  if [ "$mode" = jq ]; then run_bash "$DW" --dump-exclusions --registry "$REG" >"$tmp/new-$mode.dump" 2>"$tmp/new-$mode.err"
  else with_shim "$mode" run_bash "$DW" --dump-exclusions --registry "$REG" >"$tmp/new-$mode.dump" 2>"$tmp/new-$mode.err"; fi
  assert_eq 0 "$?" "[$mode] --dump-exclusions: exit 0"
  assert_eq "" "$(cat "$tmp/new-$mode.err")" "[$mode] --dump-exclusions: empty stderr"
  sed -n 's/^EXCL://p' "$tmp/new-$mode.dump" >"$tmp/new-$mode.excl"
  covered "$tmp/old.excl" "$tmp/new-$mode.excl" >"$tmp/cov-$mode.tsv"
  assert_eq "" "$(awk -F '\t' '$2 == "NONE" { print $1 }' "$tmp/cov-$mode.tsv")" "[$mode] every old EXCL entry is covered by a new one"
  assert_eq "$KNOWN_NONLITERAL" "$(awk -F '\t' '$2 == "under" { print $1 }' "$tmp/cov-$mode.tsv" | tr '\n' ' ' | sed 's/ $//')" \
    "[$mode] the only non-literal coverage is the known one"
  # in-house: every old key is covered by a new key of the same sdk_id
  sed -n 's/^INHOUSE://p' "$tmp/new-$mode.dump" >"$tmp/new-$mode.inhouse"
  miss=$(awk -F '|' 'NR == FNR { nw[$0] = 1; next }
    { o = $1; id = $2; ok = ((o "|" id) in nw); s = o
      while (!ok && (i = match(s, /\/[^\/]*$/)) > 0) { s = substr(s, 1, i - 1); if ((s "|" id) in nw) ok = 1 }
      if (!ok) print $0 }' "$tmp/new-$mode.inhouse" "$tmp/old.inhouse")
  assert_eq "" "$miss" "[$mode] every old in-house key is covered by a new in-house key (same sdk_id)"
done
assert_files_eq "$tmp/new-jq.dump" "$tmp/new-nojq.dump" "nojq dump == jq dump"
assert_files_eq "$tmp/new-jq.dump" "$tmp/new-jq15.dump" "jq15 dump == jq dump"
echo "new: $(wc -l <"$tmp/new-jq.excl" | tr -d ' ') EXCL, $(wc -l <"$tmp/new-jq.inhouse" | tr -d ' ') in-house keys; non-literal: $KNOWN_NONLITERAL"

# ---- the 8 apps: nojq / jq15 byte-identical to G ------------------------------------
G=$ARE_GOLD/before/adwrapper
if have_corpus && [ -d "$G" ]; then
  for app in $CORPUS_APPS; do
    D=$ARE_CORPUS/$app-decoded
    for mode in nojq jq15; do
      with_shim "$mode" run_bash "$DW" "$D" --registry "$REG" >"$tmp/$app.$mode.out" 2>"$tmp/$app.$mode.err"
      assert_eq "$(cat "$G/$app/exit")" "$?" "[$app $mode] exit code == G"
      assert_files_eq "$G/$app/stdout" "$tmp/$app.$mode.out" "[$app $mode] stdout == G"
      assert_files_eq "$G/$app/stderr" "$tmp/$app.$mode.err" "[$app $mode] stderr == G"
    done
  done
else
  echo "note: apktool corpus or $G not found: per-app nojq/jq15 check skipped"
fi
t_done
