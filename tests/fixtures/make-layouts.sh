#!/usr/bin/env bash
# tests/fixtures/make-layouts.sh <out-dir> -- the t_layouts fixture (DESIGN 5.3): one small
# app, decompiled (jadx Java) and decoded (apktool smali), arranged as the five input
# layouts of find-trackers / find-ads:
#   <out>/apktool       AndroidManifest.xml + smali/ + smali_classes2/ (+ smali_assets/,
#                       which is not app DEX code and must be ignored)
#   <out>/jadx          sources/ + resources/AndroidManifest.xml (jadx multi-line manifest)
#   <out>/jadx/sources  the same, given as its sources/ dir (jadx-sources)
#   <out>/xapk          com.example.app/{sources,resources} + config.arm64_v8a/{sources,
#                       resources} (the config split's manifest has split=; jadx-xapk)
#   <out>/tree          the Java sources and AndroidManifest.xml in one plain tree
# No proprietary code: every class is a stub written here.
set -euo pipefail
O="${1:?usage: make-layouts.sh <out-dir>}"
rm -rf "$O"; mkdir -p "$O"
J=$O/jadx

java() { # java <dotted.Class>: body from stdin
  local cls=$1 pkg simple f
  pkg=${cls%.*}; simple=${cls##*.}
  f="$J/sources/$(printf '%s' "$pkg" | tr . /)/$simple.java"
  mkdir -p "$(dirname "$f")"
  { echo "package $pkg;"; echo; cat; } >"$f"
}
stub() { printf 'public class %s {\n}\n' "${1##*.}" | java "$1"; }

stub com.google.firebase.analytics.FirebaseAnalytics
stub com.google.android.gms.ads.MobileAds
stub com.google.android.gms.ads.AdView
stub com.unity3d.ads.UnityAds
stub com.flurry.android.FlurryAgent
stub com.facebook.soloader.SoLoader
java com.example.app.MainActivity <<'EOF'
import android.os.Bundle;
import com.flurry.android.FlurryAgent;
import com.google.android.gms.ads.AdView;
import com.google.android.gms.ads.MobileAds;
import com.google.firebase.analytics.FirebaseAnalytics;
import com.unity3d.ads.UnityAds;

public class MainActivity {
    static final String AD_UNIT = "ca-app-pub-3940256099942544/6300978111";
    static final String ENDPOINT = "https://app-measurement.com/a";

    public void onCreate(Bundle bundle) {
        FirebaseAnalytics.getInstance(this).logEvent("open", bundle);
        MobileAds.initialize(this);
        UnityAds.initialize(this, "1234567", false);
        new FlurryAgent.Builder().withLogEnabled(true).build(this, "FLURRY_KEY");
    }

    public void banner(AdView adView) {
        adView.loadAd(null);
    }
}
EOF
java com.example.app.Helper <<'EOF'
public class Helper {
    public static void track(Object tracker) {
        tracker.trackEvent("x");
    }
}
EOF
mkdir -p "$J/resources"
cat >"$J/resources/AndroidManifest.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    android:versionCode="1"
    android:versionName="1.0"
    package="com.example.app">
    <uses-permission android:name="com.google.android.gms.permission.AD_ID"/>
    <application
        android:label="@string/app_name"
        android:name="com.example.app.App">
        <activity
            android:theme="@android:style/Theme.Translucent"
            android:name="com.google.android.gms.ads.AdActivity"
            android:exported="false"/>
        <meta-data
            android:name="com.google.android.gms.ads.APPLICATION_ID"
            android:value="ca-app-pub-3940256099942544~3347511713"/>
        <provider
            android:name="com.flurry.android.agent.FlurryContentProvider"
            android:authorities="com.example.app.FlurryContentProvider"/>
    </application>
</manifest>
EOF

# jadx-xapk: the base split carries the code, the config split has split= and no code
X=$O/xapk
mkdir -p "$X/com.example.app" "$X/config.arm64_v8a/sources" "$X/config.arm64_v8a/resources"
cp -R "$J/sources" "$J/resources" "$X/com.example.app/"
cat >"$X/config.arm64_v8a/resources/AndroidManifest.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.example.app"
    split="config.arm64_v8a">
    <application android:hasCode="false"/>
</manifest>
EOF

# tree: sources and manifest side by side
T=$O/tree
mkdir -p "$T"
cp -R "$J/sources/." "$T/"
cp "$J/resources/AndroidManifest.xml" "$T/AndroidManifest.xml"

# apktool: the same app in smali (one tag per manifest line), two DEX dirs
A=$O/apktool
smali() { # smali <dex-dir> <slash/Class> [body-lines...]
  local d=$1 cls=$2 f; shift 2
  f="$A/$d/$cls.smali"
  mkdir -p "$(dirname "$f")"
  { echo ".class public L$cls;"; echo ".super Ljava/lang/Object;"; for l in "$@"; do echo "$l"; done; } >"$f"
}
smali smali com/google/firebase/analytics/FirebaseAnalytics
smali smali com/google/android/gms/ads/MobileAds
smali smali_classes2 com/google/android/gms/ads/AdView
smali smali_classes2 com/unity3d/ads/UnityAds
smali smali_classes2 com/flurry/android/FlurryAgent
smali smali com/facebook/soloader/SoLoader
smali smali_assets com/mixpanel/android/mpmetrics/MixpanelAPI
smali smali com/example/app/MainActivity \
  '.field static final AD_UNIT:Ljava/lang/String; = "ca-app-pub-3940256099942544/6300978111"' \
  '.field static final ENDPOINT:Ljava/lang/String; = "https://app-measurement.com/a"' \
  '' \
  '.method public onCreate(Landroid/os/Bundle;)V' \
  '    .locals 3' \
  '    invoke-static {p0}, Lcom/google/firebase/analytics/FirebaseAnalytics;->getInstance(Landroid/content/Context;)Lcom/google/firebase/analytics/FirebaseAnalytics;' \
  '    move-result-object v0' \
  '    const-string v1, "open"' \
  '    invoke-virtual {v0, v1, p1}, Lcom/google/firebase/analytics/FirebaseAnalytics;->logEvent(Ljava/lang/String;Landroid/os/Bundle;)V' \
  '    invoke-static {p0}, Lcom/google/android/gms/ads/MobileAds;->initialize(Landroid/content/Context;)V' \
  '    const-string v1, "1234567"' \
  '    const/4 v2, 0x0' \
  '    invoke-static {p0, v1, v2}, Lcom/unity3d/ads/UnityAds;->initialize(Landroid/content/Context;Ljava/lang/String;Z)V' \
  '    new-instance v0, Lcom/flurry/android/FlurryAgent$Builder;' \
  '    invoke-direct {v0}, Lcom/flurry/android/FlurryAgent$Builder;-><init>()V' \
  '    return-void' \
  '.end method'
smali smali_classes2 com/example/app/Helper \
  '.method public static track(Ljava/lang/Object;)V' \
  '    .locals 1' \
  '    const-string v0, "x"' \
  '    invoke-virtual {p0, v0}, Lcom/example/app/Tracker;->trackEvent(Ljava/lang/String;)V' \
  '    return-void' \
  '.end method'
cat >"$A/AndroidManifest.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8" standalone="no"?><manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.example.app">
    <uses-permission android:name="com.google.android.gms.permission.AD_ID"/>
    <application android:label="@string/app_name" android:name="com.example.app.App">
        <activity android:exported="false" android:name="com.google.android.gms.ads.AdActivity" android:theme="@android:style/Theme.Translucent"/>
        <meta-data android:name="com.google.android.gms.ads.APPLICATION_ID" android:value="ca-app-pub-3940256099942544~3347511713"/>
        <provider android:authorities="com.example.app.FlurryContentProvider" android:name="com.flurry.android.agent.FlurryContentProvider"/>
    </application>
</manifest>
EOF
echo "layout fixtures written to $O"
