#!/usr/bin/env bash
# detect-protection.sh — Detect anti-tamper / integrity / licensing protection
# in an apktool-decoded APK, so the user knows BEFORE a rebuild that a
# re-signed APK of a protected app will not run.
#
# DETECTION ONLY: nothing in the decoded directory is modified, and the
# neutralizer never removes, disables or works around a protection.
#
# What it looks for:
#   - Google Play automatic protection (PairIP): class and file names seen in
#     PairIP-protected apps decoded by hand;
#   - Play Licensing library (LVL), Play Integrity and SafetyNet clients: the
#     public package names of those Google APIs;
#   - packed or hidden app code, detected generically: the components declared
#     in AndroidManifest.xml (Application, activities, services, receivers,
#     providers) are missing from the decoded code, because a packer keeps the
#     real classes in an encrypted payload. No vendor list is used, so the
#     protector is never named (apktool decodes only what is in the APK; run a
#     dedicated scanner such as APKiD when the vendor matters).
#
# Portable: bash 3.2+ (macOS) and BSD/GNU userland.
#
# Exit codes:
#   0 — check completed (whatever it found: the result is informational)
#   1 — error (invalid input, unknown option)
set -euo pipefail

usage() {
  cat <<EOF
Usage: detect-protection.sh <decoded-dir> [OPTIONS]

Detect anti-tamper, integrity and licensing protection in a directory decoded
by decode-apk.sh (apktool output). Detection only: nothing is modified.

Arguments:
  <decoded-dir>       Directory containing AndroidManifest.xml and smali*/

Options:
  -h, --help          Show this help message

Output:
  PROTECTION_DETECTED:<id>:<category>:<high|medium|low>:<evidence>[,<evidence>...]
  PROTECTION_SUMMARY:<none|integrity|license|hardener|signature-vm>

Categories (the summary is the most severe one found):
  signature-vm — Google Play PairIP with signature check / encrypted VM code:
                 a re-signed APK does not start
  hardener     — packed or hidden app code (declared components absent from the
                 decoded code): a re-signed APK does not start
  license      — license gate (PairIP license check, LVL): the app may stop at
                 a "get this app from Play" screen or refuse to run
  integrity    — Play Integrity / SafetyNet client: the app starts, a backend
                 enforcing the verdict may refuse it (often benign SDK usage)

Exit codes: 0 = check completed (informational), 1 = error
EOF
  exit "${1:-0}"
}

DECODED_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    -*)        echo "Error: Unknown option $1" >&2; usage 1 >&2 ;;
    *)
      if [[ -n "$DECODED_DIR" ]]; then
        echo "Error: only one decoded directory can be given" >&2
        exit 1
      fi
      DECODED_DIR="$1"; shift ;;
  esac
done

if [[ -z "$DECODED_DIR" ]]; then
  echo "Error: No decoded directory specified." >&2
  usage 1 >&2
fi
if [[ ! -d "$DECODED_DIR" ]]; then
  echo "Error: Not a directory: $DECODED_DIR" >&2
  exit 1
fi
DECODED_DIR=$(cd "$DECODED_DIR" && pwd -P)
MANIFEST="$DECODED_DIR/AndroidManifest.xml"
if [[ ! -f "$MANIFEST" ]]; then
  echo "Error: $DECODED_DIR has no AndroidManifest.xml (not an apktool-decoded directory?)" >&2
  exit 1
fi

# smali, smali_classes2..N, smali_assets (sorted: output is stable across runs)
SMALI_DIRS=()
while IFS= read -r d; do
  if [[ -n "$d" ]]; then SMALI_DIRS+=("$d"); fi
done < <(find "$DECODED_DIR" -mindepth 1 -maxdepth 1 -type d -name 'smali*' | LC_ALL=C sort)

# Files can sit in lib/, in assets/ (packers load their code from there) or in
# unknown/ (apktool's bucket for files outside the standard APK layout)
FILE_ROOTS=()
for r in lib assets unknown; do
  if [[ -d "$DECODED_DIR/$r" ]]; then FILE_ROOTS+=("$DECODED_DIR/$r"); fi
done

# All android:name values of the manifest (application, components, permissions)
MANIFEST_NAMES=$(grep -oE 'android:name="[^"]*"' "$MANIFEST" | sed -e 's/^android:name="//' -e 's/"$//' | LC_ALL=C sort -u || true)

MAX_EVIDENCE=5

# =====================================================================
# Rules — id|category|confidence|kind|pattern
#   manifest: an android:name in the manifest starts with <pattern>
#   class:    smali*/<pattern>.smali or the package dir smali*/<pattern>/ exists
#   file:     a file named <pattern> (glob) anywhere under lib/, assets/, unknown/
#   path:     <decoded-dir>/<pattern> (glob) exists (file or directory)
# Sources: PairIP = seen in PairIP-protected apps; LVL, Play Integrity and
# SafetyNet = public package names of Google APIs. Packed code is not a rule
# table: it is the generic check_packed_code below.
# =====================================================================
RULES='
pairip-license|license|high|manifest|com.pairip.application.Application
pairip-license|license|high|manifest|com.pairip.licensecheck.
pairip-license|license|high|class|com/pairip/licensecheck/LicenseClient
pairip-license|license|high|class|com/pairip/licensecheck/LicenseContentProvider
pairip-signature-vm|signature-vm|high|class|com/pairip/SignatureCheck
pairip-signature-vm|signature-vm|high|class|com/pairip/VMRunner
pairip-signature-vm|signature-vm|high|class|com/pairip/VmDecryptor
pairip-signature-vm|signature-vm|high|file|libpairipcore.so
lvl|license|medium|class|com/google/android/vending/licensing
play-integrity|integrity|low|class|com/google/android/play/core/integrity
safetynet|integrity|low|class|com/google/android/gms/safetynet
'

FOUND=""   # lines: id|confidence|evidence
add_evidence() { FOUND="${FOUND}$1|$2|$3"$'\n'; }
has_id() { case $'\n'"$FOUND" in *$'\n'"$1|"*) return 0 ;; esac; return 1; }
rel() { printf '%s\n' "${1#"$DECODED_DIR"/}"; }

match_manifest() {
  local id="$1" conf="$2" pat="$3" n=0 name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    case "$name" in
      "$pat"*)
        add_evidence "$id" "$conf" "manifest=$name"
        n=$((n + 1))
        if [[ $n -ge $MAX_EVIDENCE ]]; then return 0; fi ;;
    esac
  done <<< "$MANIFEST_NAMES"
  return 0
}

# First match only: the same package is often split across several classesN.dex
match_class() {
  local id="$1" conf="$2" pat="$3" s
  if [[ ${#SMALI_DIRS[@]} -eq 0 ]]; then return 0; fi
  for s in "${SMALI_DIRS[@]}"; do
    if [[ -f "$s/$pat.smali" ]]; then
      add_evidence "$id" "$conf" "class=$(rel "$s/$pat.smali")"; return 0
    elif [[ -d "$s/$pat" ]]; then
      add_evidence "$id" "$conf" "class=$(rel "$s/$pat")/"; return 0
    fi
  done
  return 0
}

match_file() {
  local id="$1" conf="$2" pat="$3" n=0 f
  if [[ ${#FILE_ROOTS[@]} -eq 0 ]]; then return 0; fi
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    add_evidence "$id" "$conf" "file=$(rel "$f")"
    n=$((n + 1))
    if [[ $n -ge $MAX_EVIDENCE ]]; then return 0; fi
  done < <(find "${FILE_ROOTS[@]}" -type f -name "$pat" 2>/dev/null | LC_ALL=C sort)
  return 0
}

match_path() {
  local id="$1" conf="$2" pat="$3" n=0 p
  # Unquoted on purpose: the pattern is a glob (no pattern contains spaces)
  for p in "$DECODED_DIR"/$pat; do
    [[ -e "$p" ]] || continue
    add_evidence "$id" "$conf" "path=$(rel "$p")"
    n=$((n + 1))
    if [[ $n -ge $MAX_EVIDENCE ]]; then return 0; fi
  done
  return 0
}

IDS=""   # ordered, unique
while IFS='|' read -r id cat conf kind pat; do
  [[ -z "$id" ]] && continue
  case " $IDS " in *" $id "*) ;; *) IDS="$IDS $id" ;; esac
  case "$kind" in
    manifest) match_manifest "$id" "$conf" "$pat" ;;
    class)    match_class "$id" "$conf" "$pat" ;;
    file)     match_file "$id" "$conf" "$pat" ;;
    path)     match_path "$id" "$conf" "$pat" ;;
  esac
done <<< "$RULES"

# Packed or hidden app code: a packer ships a stub and keeps the real classes
# in an encrypted payload, so most components declared in the manifest have no
# class in the decoded smali. Clean apps miss only a few (library activities
# stripped by the shrinker). Needs >= 3 declared classes and >= 3 missing.
#   >= 50% missing -> medium, >= 80% -> high.
check_packed_code() {
  local id=packed-code tmp present declared missing total miss pct conf n=0 c
  if [[ ${#SMALI_DIRS[@]} -eq 0 ]]; then return 0; fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/detect-protection.XXXXXX") || return 0
  present="$tmp/present"; declared="$tmp/declared"; missing="$tmp/missing"
  local s
  for s in "${SMALI_DIRS[@]}"; do
    (cd "$s" && find . -type f -name '*.smali' 2>/dev/null | sed -e 's#^\./##' -e 's#\.smali$##')
  done | LC_ALL=C sort -u > "$present"
  # activity-alias is not matched (its name is not a class); android.* classes
  # belong to the framework and are never in the APK.
  tr '\n' ' ' < "$MANIFEST" | grep -oE '<(manifest|application|activity|service|receiver|provider)[[:space:]][^>]*>' | awk '
    /^<manifest/ { if (match($0, /package="[^"]*"/)) pkg = substr($0, RSTART + 9, RLENGTH - 10); next }
    { if (match($0, /android:name="[^"]*"/)) {
        nm = substr($0, RSTART + 14, RLENGTH - 15)
        if (nm ~ /^\./) nm = pkg nm
        else if (nm !~ /\./) nm = pkg "." nm
        if (nm ~ /^android\./) next
        gsub(/\./, "/", nm); print nm } }' | LC_ALL=C sort -u > "$declared"
  total=$(wc -l < "$declared" | tr -d ' ')
  LC_ALL=C comm -23 "$declared" "$present" > "$missing"
  miss=$(wc -l < "$missing" | tr -d ' ')
  if [[ "$total" -ge 3 ]] && [[ "$miss" -ge 3 ]]; then
    pct=$(( miss * 100 / total ))
    conf=""
    if [[ $pct -ge 80 ]]; then conf=high; elif [[ $pct -ge 50 ]]; then conf=medium; fi
    if [[ -n "$conf" ]]; then
      case " $IDS " in *" $id "*) ;; *) IDS="$IDS $id" ;; esac
      add_evidence "$id" "$conf" "declared-classes-missing=$miss/$total"
      while IFS= read -r c; do
        add_evidence "$id" "$conf" "absent=$c"
        n=$((n + 1)); if [[ $n -ge 3 ]]; then break; fi
      done < "$missing"
    fi
  fi
  rm -rf "$tmp"
  return 0
}
check_packed_code

category_of() {
  if [[ "$1" == packed-code ]]; then echo hardener; return 0; fi
  printf '%s\n' "$RULES" | awk -F'|' -v id="$1" '$1 == id { print $2; exit }'
}
name_of() {
  case "$1" in
    pairip-signature-vm) echo "Google Play automatic protection (PairIP: signature check + encrypted VM code)" ;;
    pairip-license)      echo "Google Play automatic protection (PairIP: license check only)" ;;
    lvl)                 echo "Google Play Licensing library (LVL)" ;;
    packed-code)         echo "a packer: app code hidden in a payload (declared components missing from the decoded code)" ;;
    play-integrity)      echo "Play Integrity API client" ;;
    safetynet)           echo "SafetyNet Attestation client" ;;
    *)                   echo "$1" ;;
  esac
}
cat_rank() {
  case "$1" in
    signature-vm) echo 4 ;; hardener) echo 3 ;; license) echo 2 ;; integrity) echo 1 ;; *) echo 0 ;;
  esac
}
conf_rank() { case "$1" in high) echo 3 ;; medium) echo 2 ;; low) echo 1 ;; *) echo 0 ;; esac; }

# =====================================================================
# Report
# =====================================================================
echo "=== Protection check (detection only): $DECODED_DIR ==="
SUMMARY=none
BLOCKERS=""        # names of hard blockers (signature-vm, hardener)
BLOCKER_CONF=""    # lowest confidence among them
for id in $IDS; do
  has_id "$id" || continue
  # PairIP: the signature/VM variant already implies the license check; report
  # it once, with the license evidence folded in.
  if [[ "$id" == pairip-license ]] && has_id pairip-signature-vm; then continue; fi
  cat=$(category_of "$id")
  conf=""; evidence=""; n=0
  sources="$id"
  if [[ "$id" == pairip-signature-vm ]]; then sources="$id pairip-license"; fi
  for src in $sources; do   # the id's own evidence first
    while IFS='|' read -r eid econf edetail; do
      [[ "$eid" == "$src" ]] || continue
      if [[ $(conf_rank "$econf") -gt $(conf_rank "$conf") ]]; then conf="$econf"; fi
      if [[ $n -lt $MAX_EVIDENCE ]]; then
        evidence="${evidence:+$evidence,}$edetail"
        n=$((n + 1))
      fi
    done <<< "$FOUND"
  done
  echo "PROTECTION_DETECTED:$id:$cat:$conf:$evidence"
  echo "  -> $(name_of "$id") [$cat, $conf confidence]"
  if [[ $(cat_rank "$cat") -gt $(cat_rank "$SUMMARY") ]]; then SUMMARY="$cat"; fi
  case "$cat" in
    signature-vm|hardener)
      BLOCKERS="${BLOCKERS:+$BLOCKERS, }$(name_of "$id")"
      if [[ -z "$BLOCKER_CONF" ]] || [[ $(conf_rank "$conf") -lt $(conf_rank "$BLOCKER_CONF") ]]; then
        BLOCKER_CONF="$conf"
      fi ;;
  esac
done
echo "PROTECTION_SUMMARY:$SUMMARY"

case "$SUMMARY" in
  signature-vm|hardener)
    echo
    echo "!!! WARNING: this app is protected by $BLOCKERS."
    if [[ "$BLOCKER_CONF" == high ]]; then
      echo "!!! A rebuilt and re-signed APK will NOT run:"
    else
      echo "!!! A rebuilt and re-signed APK will most likely NOT run (medium-confidence match):"
    fi
    echo "!!! the protection checks the signing certificate and/or hides its code in an encrypted payload loaded at startup."
    echo "!!! Neutralization can still produce a report, but the rebuilt APK will not be usable."
    echo "!!! The neutralizer does not remove or bypass protections. Tell the user before spending"
    echo "!!! time on a rebuild." ;;
  license)
    echo
    echo "!!! WARNING: this app has a Google Play license gate. A rebuilt and re-signed APK may stop at"
    echo "!!! a 'Get this app from Play' screen or refuse to run. Tell the user before a rebuild." ;;
  integrity)
    echo "Note: Play Integrity / SafetyNet client code found (often bundled by SDKs). The app starts;"
    echo "a backend that enforces the verdict may refuse the re-signed APK (login, purchases, online play)." ;;
  none)
    echo "No PairIP, Google licensing/integrity client or packed code detected (this does not rule out"
    echo "an app-specific protection that hides nothing from the decoded tree)." ;;
esac
exit 0
