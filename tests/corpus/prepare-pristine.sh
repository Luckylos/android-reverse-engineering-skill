#!/usr/bin/env bash
# prepare-pristine.sh -- fresh (pristine) apktool decodes of the corpus originals into
# $ARE_PRISTINE/<app> (DESIGN 9.2 "Ground truth", Q4): the <app>-decoded dirs of test_apks
# were neutralized in place, so the ground-truth gates (groundtruth.sh, marker-verify.sh)
# run on these decodes instead. Not a test (run.sh skips it): run it once, 10-20 min.
# Usage: tests/corpus/prepare-pristine.sh [<app>...]     (default: all 9 apps; an existing
#        $ARE_PRISTINE/<app> is kept: remove it to decode again)
# Decoder: decode-apk.sh of the plugin under test (APKEditor merge for split bundles).
# Sources (explicit table; T = $ARE_CORPUS):
#   af1945      T/1945+Air+Force_+Plane+Shooter_15.82_APKPure.xapk
#   alto        T/Alto's+Adventure_1.8.27_APKPure.xapk
#   badpiggies  T/Bad+Piggies+HD_2.4.3379_APKPure.xapk
#   blockcraft  T/Block+Craft+3D：Building+Game_4.5.1_APKPure.xapk   (full-width colon)
#   bulldozer   T/Bulldozer+Master_+Crush+&+Mine_11.1.0_APKPure.xapk
#   subway      T/Subway+Surfers_3.69.2_APKPure.apk
#   ttom2       T/My+Talking+Tom+2_0.7_APKPure.xapk
#   heartstar   <home>/re-test5/HeartStar_1.2.5_align.apk  (test_apks only has the neutralized APK)
#   watersort   <home>/re-test3/Water Sort Puzzle - Sort Color_4.20.0_APKPure.xapk
# Exit: 0 all requested decodes exist, 1 a decode failed or a source is missing.
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

T=$ARE_CORPUS
HOMEP=$(dirname "$ARE_WORKSPACE")
src() {
  case "$1" in
    af1945)     echo "$T/1945+Air+Force_+Plane+Shooter_15.82_APKPure.xapk" ;;
    alto)       echo "$T/Alto's+Adventure_1.8.27_APKPure.xapk" ;;
    badpiggies) echo "$T/Bad+Piggies+HD_2.4.3379_APKPure.xapk" ;;
    blockcraft) echo "$T/Block+Craft+3D：Building+Game_4.5.1_APKPure.xapk" ;;
    bulldozer)  echo "$T/Bulldozer+Master_+Crush+&+Mine_11.1.0_APKPure.xapk" ;;
    subway)     echo "$T/Subway+Surfers_3.69.2_APKPure.apk" ;;
    ttom2)      echo "$T/My+Talking+Tom+2_0.7_APKPure.xapk" ;;
    heartstar)  echo "$HOMEP/re-test5/HeartStar_1.2.5_align.apk" ;;
    watersort)  echo "$HOMEP/re-test3/Water Sort Puzzle - Sort Color_4.20.0_APKPure.xapk" ;;
    *) return 1 ;;
  esac
}
[ $# -gt 0 ] || set -- af1945 alto badpiggies blockcraft bulldozer subway ttom2 heartstar watersort
mkdir -p "$ARE_PRISTINE" || { echo "cannot create $ARE_PRISTINE" >&2; exit 1; }
rc=0
for a in "$@"; do
  f=$(src "$a") || { echo "FAIL $a: unknown app" >&2; rc=1; continue; }
  if [ -d "$ARE_PRISTINE/$a" ]; then echo "SKIP $a (exists)"; continue; fi
  if [ ! -f "$f" ]; then echo "FAIL $a: source not found: $f" >&2; rc=1; continue; fi
  echo "START $a"
  if bash "$NS/decode-apk.sh" "$f" -o "$ARE_PRISTINE/$a" >"$ARE_PRISTINE/$a.log" 2>&1; then echo "DONE $a"
  else echo "FAIL $a (see $ARE_PRISTINE/$a.log)" >&2; rc=1; fi
done
exit "$rc"
