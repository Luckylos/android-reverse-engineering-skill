#!/usr/bin/env bash
# tests/fixtures/make-synth48.sh <registry-dir> <out-dir> -- generate the synth48
# fixture (apktool layout) from a registry (DESIGN 9.2): a minimal AndroidManifest.xml
# declaring every manifest_components class, and under smali/
#   - one minimal .smali per class named in targets.entry_points / targets.ad_operations,
#     declaring every target method with its registry signature (`()V` when `*`);
#   - one .smali per package of `packages` (so every entry matches in registry-scan).
# It makes target generation at depth 1-3 byte-comparable for every entry, also those
# that never match in the corpus (adjust, amplitude, mixpanel, braze, ...).
# The golden baseline (G-synth, tests/golden/synth48.before) is generated from the
# registry of 4c166fe, so tests/golden/capture.sh always feeds this script that
# registry (git archive), never the registry under test.
# Output is deterministic: files are generated in sorted order, no timestamps.
set -euo pipefail
export LC_ALL=C
R="${1:?usage: make-synth48.sh <registry-dir> <out-dir>}"
D="${2:?usage: make-synth48.sh <registry-dir> <out-dir>}"
[ -d "$R" ] || { echo "make-synth48: registry not found: $R" >&2; exit 1; }
rm -rf "$D"
mkdir -p "$D/smali"

files=()
for f in "$R"/*.json; do
  case "$(basename "$f")" in _*) continue ;; esac
  files+=("$f")
done
[ "${#files[@]}" -gt 0 ] || { echo "make-synth48: no entries in $R" >&2; exit 1; }

# ---- manifest ----------------------------------------------------------------------
{
  echo '<?xml version="1.0" encoding="utf-8" standalone="no"?><manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.synth48.app">'
  echo '    <application android:label="synth48">'
  jq -r '.manifest_components[]? | "\(.type)\t\(.class)"' "${files[@]}" | sort -u |
  while IFS="$(printf '\t')" read -r type cls; do
    case "$type" in
      provider) echo "        <provider android:authorities=\"$cls.synth48\" android:exported=\"false\" android:name=\"$cls\"/>" ;;
      activity|service|receiver) echo "        <$type android:exported=\"false\" android:name=\"$cls\"/>" ;;
      *) echo "        <!-- unknown component type $type --><activity android:exported=\"false\" android:name=\"$cls\"/>" ;;
    esac
  done
  echo '    </application>'
  echo '</manifest>'
} >"$D/AndroidManifest.xml"

# ---- target classes ------------------------------------------------------------------
# class<TAB>method<TAB>signature, unique and sorted
jq -r '.targets // {} | (.entry_points // []) + (.ad_operations // []) | .[]
       | .class as $c | .methods[] | "\($c)\t\(.name)\t\(.signature // "*")"' "${files[@]}" |
  sort -u >"$D/.targets.tsv"

ret_body() { # smali body returning a zero value of the return type $1
  case "$1" in
    V) printf '    return-void\n' ;;
    J|D) printf '    const-wide/16 v0, 0x0\n\n    return-wide v0\n' ;;
    Z|B|S|C|I|F) printf '    const/4 v0, 0x0\n\n    return v0\n' ;;
    *) printf '    const/4 v0, 0x0\n\n    return-object v0\n' ;;
  esac
}

cur=""
out=""
while IFS="$(printf '\t')" read -r cls meth sig; do
  [ "$sig" = "*" ] && sig="()V"
  if [ "$cls" != "$cur" ]; then
    cur=$cls
    path=$(printf '%s' "$cls" | tr . /)
    out="$D/smali/$path.smali"
    mkdir -p "$(dirname "$out")"
    printf '.class public L%s;\n.super Ljava/lang/Object;\n.source "synth48"\n\n\n# direct methods' "$path" >"$out"
  fi
  ret=${sig##*)}
  printf '\n.method public static %s%s\n    .locals 2\n\n' "$meth" "$sig" >>"$out"
  ret_body "$ret" >>"$out"
  printf '.end method\n' >>"$out"
done <"$D/.targets.tsv"
rm -f "$D/.targets.tsv"

# ---- one class per package ---------------------------------------------------------
jq -r '.packages[]?' "${files[@]}" | sort -u | while IFS= read -r pkg; do
  [ -n "$pkg" ] || continue
  path=$(printf '%s' "$pkg" | tr . /)/Synth48Package
  mkdir -p "$D/smali/$(dirname "$path")"
  [ -e "$D/smali/$path.smali" ] ||
    printf '.class public L%s;\n.super Ljava/lang/Object;\n.source "synth48"\n' "$path" >"$D/smali/$path.smali"
done

echo "synth48: $(find "$D/smali" -name '*.smali' | wc -l | tr -d ' ') smali file(s), $(grep -c 'android:name=' "$D/AndroidManifest.xml") manifest component(s) from ${#files[@]} entries -> $D" >&2
