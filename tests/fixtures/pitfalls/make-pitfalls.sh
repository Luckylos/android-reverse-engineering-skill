#!/usr/bin/env bash
# tests/fixtures/pitfalls/make-pitfalls.sh <out-dir> -- generate the pitfall fixtures of
# DESIGN 9.2 (t_pitfalls): tiny synthetic decode trees, one directory per case, that
# reproduce the false positives / false negatives of the legacy find-trackers.sh /
# find-ads.sh. No proprietary code: every class body is a stub written here.
# Layouts: `jadx` = <case>/sources + <case>/resources/AndroidManifest.xml;
#          `apktool` = <case>/AndroidManifest.xml + <case>/smali.
# The expectations live in tests/unit/t_pitfalls.sh (one block per case, same ids).
set -euo pipefail
O="${1:?usage: make-pitfalls.sh <out-dir>}"
rm -rf "$O"; mkdir -p "$O"

# ---- writers -----------------------------------------------------------------------------
manifest_jadx() { # manifest_jadx <case> [body-lines...]: jadx style, one attribute per line
  local c=$1; shift
  mkdir -p "$O/$c/resources"
  {
    echo '<?xml version="1.0" encoding="utf-8"?>'
    echo '<manifest xmlns:android="http://schemas.android.com/apk/res/android"'
    echo '    android:versionCode="1"'
    echo '    android:versionName="1.0"'
    echo '    package="com.example.app">'
    echo '    <application'
    echo '        android:label="@string/app_name"'
    echo '        android:name="com.example.app.App">'
    for l in "$@"; do echo "$l"; done
    echo '    </application>'
    echo '</manifest>'
  } >"$O/$c/resources/AndroidManifest.xml"
}
manifest_apktool() { # manifest_apktool <case> [body-lines...]: apktool style, one line per tag
  local c=$1; shift
  mkdir -p "$O/$c"
  {
    echo '<?xml version="1.0" encoding="utf-8" standalone="no"?><manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.example.app">'
    echo '    <application android:label="@string/app_name" android:name="com.example.app.App">'
    for l in "$@"; do echo "$l"; done
    echo '    </application>'
    echo '</manifest>'
  } >"$O/$c/AndroidManifest.xml"
}
java() { # java <case> <dotted.Class> [<header-comment>] : body from stdin (may be empty)
  local c=$1 cls=$2 hdr=${3:-} pkg simple f
  pkg=${cls%.*}; simple=${cls##*.}
  f="$O/$c/sources/$(printf '%s' "$pkg" | tr . /)/$simple.java"
  mkdir -p "$(dirname "$f")"
  {
    echo "package $pkg;"
    echo
    [ -z "$hdr" ] || echo "$hdr"
    cat
  } >"$f"
}
stub_java() { # stub_java <case> <dotted.Class> [<header-comment>]: an empty public class
  printf 'public class %s {\n}\n' "${2##*.}" | java "$@"
}
smali() { # smali <case> <slash/Class> [body-lines...]
  local c=$1 cls=$2 f; shift 2
  f="$O/$c/smali/$cls.smali"
  mkdir -p "$(dirname "$f")"
  {
    echo ".class public L$cls;"
    echo ".super Ljava/lang/Object;"
    for l in "$@"; do echo "$l"; done
  } >"$f"
}
app_main_smali() { smali "$1" com/example/app/App; }

# ---- P01 FirebaseAnalytics.getInstance(this): a call with arguments is a call --------------
c=p01-firebase-getinstance-args
manifest_jadx $c
stub_java $c com.google.firebase.analytics.FirebaseAnalytics
java $c com.example.app.MainActivity <<'EOF'
import com.google.firebase.analytics.FirebaseAnalytics;

public class MainActivity {
    private FirebaseAnalytics mFirebaseAnalytics;

    public void onCreate() {
        this.mFirebaseAnalytics = FirebaseAnalytics.getInstance(this);
    }
}
EOF

# ---- P02 "ca-app-pub-1234..." : an id followed by digits is still an AdMob id -------------------
c=p02-admob-id-digits
manifest_jadx $c
stub_java $c com.google.android.gms.ads.MobileAds
java $c com.example.app.AdConfig <<'EOF'
public class AdConfig {
    public static final String BANNER = "ca-app-pub-1234567890123456/1234567890";
}
EOF

# ---- P03 jadx manifest with android:name on its own line ---------------------------------------------
c=p03-jadx-multiline-manifest
manifest_jadx $c \
  '        <activity' \
  '            android:theme="@android:style/Theme.Translucent"' \
  '            android:name="com.google.android.gms.ads.AdActivity"' \
  '            android:exported="false"/>' \
  '        <meta-data' \
  '            android:name="com.google.android.gms.ads.APPLICATION_ID"' \
  '            android:value="ca-app-pub-3940256099942544~3347511713"/>'
stub_java $c com.example.app.App

# ---- P04 SDK names inside com/safedk are library strings, never LOW -------------------------------
c=p04-safedk-sdk-strings
manifest_jadx $c
stub_java $c com.example.app.App
java $c com.safedk.android.analytics.SdksMapping <<'EOF'
public class SdksMapping {
    static final String[] PACKAGES = {"com.mixpanel.android", "com.adjust.sdk", "com.appsflyer",
        "com.amplitude.api", "com.unity3d.ads", "com.flurry.android", "com.braze"};
    static final String[] HOSTS = {"api.mixpanel.com", "app.adjust.com", "t.appsflyer.com"};
}
EOF

# ---- P05 GuruAnalytics.Builder is not Segment (legacy `Analytics.Builder` regex) ---------------------
c=p05-guru-analytics-builder
manifest_jadx $c
stub_java $c com.guru.analytics.GuruAnalytics
java $c com.example.app.App <<'EOF'
import com.guru.analytics.GuruAnalytics;

public class App {
    public void onCreate() {
        new GuruAnalytics.Builder(this).setAppId("x").build();
    }
}
EOF

# ---- P06 FirebaseAnalytics.Param.* inside com/bytedance (SDK code, not evidence) -------------------
c=p06-firebase-param-in-bytedance
manifest_jadx $c
stub_java $c com.example.app.App
java $c com.bytedance.sdk.openadsdk.core.EventMapper <<'EOF'
import com.google.firebase.analytics.FirebaseAnalytics;

public class EventMapper {
    static String map() {
        return FirebaseAnalytics.Param.ITEM_ID + FirebaseAnalytics.Event.AD_IMPRESSION;
    }
}
EOF

# ---- P07 gms/ads/identifier alone: AdMob at most LOW ----------------------------------------------
c=p07-gms-ads-identifier-only
manifest_apktool $c
app_main_smali $c
smali $c com/google/android/gms/ads/identifier/AdvertisingIdClient
smali $c 'com/google/android/gms/ads/identifier/AdvertisingIdClient$Info'

# ---- P08 com/facebook/ads alone: Facebook SDK (social) not HIGH -----------------------------------
c=p08-facebook-ads-only
manifest_apktool $c
app_main_smali $c
smali $c com/facebook/ads/AudienceNetworkAds
smali $c com/facebook/ads/AdView
smali $c com/facebook/ads/InterstitialAd

# ---- P09 com/explorestack/protobuf (BidMachine): Appodeal NONE ---------------------------------------
c=p09-explorestack-protobuf
manifest_apktool $c
app_main_smali $c
smali $c com/explorestack/protobuf/GeneratedMessageV3
smali $c com/explorestack/protobuf/ByteString

# ---- P10 Tapjoy declared only in the manifest: MEDIUM ---------------------------------------------------
c=p10-tapjoy-manifest-only
manifest_apktool $c \
  '        <activity android:configChanges="orientation|keyboardHidden|screenSize" android:name="com.tapjoy.TJAdUnitActivity"/>'
app_main_smali $c

# ---- P11 mFirebaseAnalytics.logEvent( : import-scoped instance call; no import = no call ----------
c=p11-firebase-logevent-instance
manifest_jadx $c
stub_java $c com.google.firebase.analytics.FirebaseAnalytics
java $c com.example.app.WithImport <<'EOF'
import android.os.Bundle;
import com.google.firebase.analytics.FirebaseAnalytics;

public class WithImport {
    private FirebaseAnalytics mFirebaseAnalytics;

    public void levelUp(Bundle bundle) {
        this.mFirebaseAnalytics.logEvent("level_up", bundle);
    }
}
EOF
java $c com.example.app.NoImport <<'EOF'
import android.os.Bundle;

public class NoImport {
    private Tracker mFirebaseAnalytics;

    public void levelUp(Bundle bundle) {
        this.mFirebaseAnalytics.logEvent("level_up", bundle);
    }
}
EOF

# ---- P12 new FlurryAgent.Builder().withLogEnabled(true).build( : Flurry init ------------------------
c=p12-flurry-builder-chain
manifest_jadx $c
stub_java $c com.flurry.android.FlurryAgent
java $c com.example.app.App <<'EOF'
import com.flurry.android.FlurryAgent;

public class App {
    public void onCreate() {
        new FlurryAgent.Builder().withLogEnabled(true).build(this, "FLURRY_API_KEY");
    }
}
EOF

# ---- P13 COPPA: RequestConfiguration.TAG_FOR_CHILD_DIRECTED_TREATMENT_TRUE and setCOPPA( ---------------
c=p13-coppa
manifest_jadx $c
stub_java $c com.google.android.gms.ads.MobileAds
stub_java $c com.google.android.gms.ads.RequestConfiguration
java $c com.example.app.Consent <<'EOF'
import com.google.android.gms.ads.RequestConfiguration;

public class Consent {
    public void apply(Object sdk) {
        int tag = RequestConfiguration.TAG_FOR_CHILD_DIRECTED_TREATMENT_TRUE;
        ((Kids) sdk).setCOPPA(true);
    }
}
EOF

# ---- P14 jadx package alias com/json -> com.ironsource (alto) ------------------------------------------
c=p14-jadx-alias-com-json
manifest_jadx $c
for n in a1 b2 c3; do
  stub_java $c com.json.$n "/* JADX INFO: renamed from: com.ironsource.$n, reason: invalid class name */"
done
for i in $(seq 1 20); do stub_java $c com.json.z$i; done
stub_java $c com.json.mediationsdk.IronSource
stub_java $c com.json.mediationsdk.logger.IronSourceError
java $c com.example.app.Ads <<'EOF'
import com.json.mediationsdk.IronSource;

public class Ads {
    public void init() {
        IronSource.init(this, "APP_KEY");
    }
}
EOF

# ---- P15 jadx package alias org/json -> com.ironsource, adqualitysdk stays library (bulldozer) --------
c=p15-jadx-alias-org-json
manifest_jadx $c
for n in a1 b2 c3; do
  stub_java $c org.json.$n "/* JADX INFO: renamed from: com.ironsource.$n, reason: invalid class name */"
done
for i in $(seq 1 20); do stub_java $c org.json.z$i; done
stub_java $c org.json.mediationsdk.IronSource
java $c org.json.adqualitysdk.sdk.i.SdkList <<'EOF'
public class SdkList {
    static final String[] SDKS = {"com.applovin.sdk", "com.unity3d.ads", "com.google.android.gms.ads"};
}
EOF
java $c com.example.app.Ads <<'EOF'
import org.json.mediationsdk.IronSource;

public class Ads {
    public void init() {
        IronSource.init(this, "APP_KEY");
    }
}
EOF

# ---- P16 com/facebook/soloader alone: Facebook NONE, nothing in Entry Points ---------------------------
c=p16-facebook-soloader-only
manifest_jadx $c
stub_java $c com.facebook.soloader.SoLoader
java $c com.example.app.App <<'EOF'
import com.facebook.soloader.SoLoader;

public class App {
    public void onCreate() {
        SoLoader.init(this, false);
    }
}
EOF

# ---- P17 gms/internal smali that references Lcom/google/android/gms/ads/ is library -----------------------
c=p17-gms-internal-refs-ads
manifest_apktool $c
app_main_smali $c
smali $c com/google/android/gms/ads/MobileAds
smali $c com/google/android/gms/internal/xyz/A \
  '' \
  '.method public static a()V' \
  '    .locals 0' \
  '    invoke-static {}, Lcom/google/android/gms/ads/MobileAds;->initialize()V' \
  '    return-void' \
  '.end method'

# ---- P18 manifest with only FirebaseInstanceIdReceiver (FCM): Firebase Analytics NONE -----------------
c=p18-fcm-receiver-only
manifest_apktool $c \
  '        <receiver android:exported="true" android:name="com.google.firebase.iid.FirebaseInstanceIdReceiver" android:permission="com.google.android.c2dm.permission.SEND"/>'
app_main_smali $c

# ---- P19 wildcard imports (`import pkg.*;`) make the SDK classes visible like explicit imports ------
# (DESIGN 5.4 step 4): MobileAds is a class of the tree, FirebaseAnalytics only an API fact (no file);
# NoWild.java has no wildcard import, so its MobileAds is not the SDK class
c=p19-wildcard-import
manifest_jadx $c
stub_java $c com.google.android.gms.ads.MobileAds
java $c com.example.app.WildAds <<'JEOF'
import com.google.android.gms.ads.*;

public class WildAds {
    public void start() {
        MobileAds.initialize(this);
    }
}
JEOF
java $c com.example.app.WildAnalytics <<'JEOF'
import android.os.Bundle;
import com.google.firebase.analytics.*;

public class WildAnalytics {
    public void levelUp(Bundle bundle) {
        FirebaseAnalytics.getInstance(this).logEvent("level_up", bundle);
    }
}
JEOF
java $c com.example.app.NoWild <<'JEOF'
public class NoWild {
    public void start() {
        MobileAds.initialize(this);
    }
}
JEOF

echo "pitfall fixtures written to $O"
