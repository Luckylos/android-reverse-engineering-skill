#!/usr/bin/env bash
# tests/fixtures/make-adwrapper-fixture.sh <dir> -- synthetic apktool-like decoded dir that
# exercises the registry-dependent paths of detect-adwrapper (registry exclusions and the
# in_house_wrapper annotation) and of registry-scan (package matching, including
# single-segment and non-`com` prefixes). Port of
# registry-unification/scratch/contract/make-fixture.sh.
# Expected detect-adwrapper lines (ADWRAPPER_* only): tests/fixtures/expected/adwrapper-fixture.txt
# (checked by tests/unit/t_adwrapper.sh). History (DESIGN 6): captured with the product of
# 4c166fe; since the .packages reader (commit 3) tv.superawesome.lib, yads.core.impl and
# backtraceio.library.sub are gone (registry packages the legacy grep missed); with the
# `segment` entry (commit 7a) com.segment.analytics disappears too.
set -euo pipefail
D="${1:?usage: make-adwrapper-fixture.sh <dir>}"; rm -rf "$D"; mkdir -p "$D"
cat >"$D/AndroidManifest.xml" <<'XML'
<?xml version="1.0" encoding="utf-8" standalone="no"?><manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.example.app">
<application><activity android:name="com.google.android.gms.ads.AdActivity"/><service android:name="com.stencyl.extension.FooService"/></application></manifest>
XML
cls() { # cls <smali-dir> <slash/Class> [refs...]
  local s="$1" c="$2" r; shift 2; mkdir -p "$D/$s/$(dirname "$c")"
  { echo ".class public L$c;"; echo ".super Ljava/lang/Object;"
    for r in "$@"; do echo "    invoke-static {}, L$r;->init()V"; done; } >"$D/$s/$c.smali"
}
two="com/applovin/sdk/AppLovinSdk com/unity3d/ads/UnityAds"
# registry packages the legacy grep does NOT extract (tv.*, single segment)
for i in 1 2 3; do cls smali "tv/superawesome/lib/AdsLoader$i" $two; done
for i in 1 2 3; do cls smali "yads/core/impl/AdManagerX$i" $two; done
for i in 1 2 3; do cls smali "backtraceio/library/sub/AdsTracking$i" $two; done
# in-house wrapper with a registry entry
for i in 1 2 3; do cls smali_classes2 "com/rovio/beacon/ads/InterstitialAds$i" $two; done
# vendor-owned wrapper, no registry entry
for i in 1 2 3; do cls smali_classes2 "com/example/ads/InterstitialManager$i" $two; done
# network SDK packages (so registry-scan matches something)
cls smali com/google/android/gms/ads/MobileAds
cls smali com/unity3d/ads/UnityAds
cls smali com/applovin/sdk/AppLovinSdk
# a package only a detection-only entry would know
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do cls smali "com/segment/analytics/AnalyticsTracking$i" $two; done
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do cls smali "com/stencyl/extension/Ext$i"; done
echo "fixture at $D"
