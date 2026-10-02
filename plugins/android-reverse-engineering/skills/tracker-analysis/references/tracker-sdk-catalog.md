# Tracker SDK Catalog

The SDK registry `skills/sdk-neutralizer/registry/*.json` is the **single source** of the packages, marker classes, manifest names, endpoint domains and APIs used to detect tracker SDKs (the `detection` object of each entry, plus `packages` and `targets`). This page no longer lists them, so it cannot drift from what the scripts do.

- **Live list**: `bash ${CLAUDE_PLUGIN_ROOT}/skills/tracker-analysis/scripts/find-trackers.sh --list-sdks` (TSV: `sdk_id`, `category`, `legacy_flag`, `neutralizable`, `packages`). Every entry of the categories analytics, attribution, crash_reporting and social is audited.
- **One entry in detail**: `jq . ${CLAUDE_PLUGIN_ROOT}/skills/sdk-neutralizer/registry/<sdk_id>.json`.
- **Adding an SDK**: add a registry entry (`<sdk_id>.json`, see `_schema.json`). `targets` is optional: an entry without it is *detection-only* (the audit sees it, `registry-scan.py` and `neutralize.sh` ignore it). Known gaps are tracked in `skills/sdk-neutralizer/references/registry-backlog.md`.

## Notes per SDK (documentation only)

| SDK | Notes | Gradle |
|---|---|---|
| Firebase Analytics | Google's app analytics on top of the Play services measurement module (`com.google.android.gms.measurement`); events go to `app-measurement.com`. `analytics/connector` alone (Crashlytics, FCM) is not Analytics. | `com.google.firebase:firebase-analytics` |
| Adjust | Attribution. v4 initializes with `Adjust.onCreate(AdjustConfig)`, v5 with `Adjust.initSdk`. | `com.adjust.sdk:adjust-android` |
| AppsFlyer | Attribution. The public API is `AppsFlyerLib`; the SDK builds its endpoint URLs with `%s`, so the bare host (`appsflyer.com`) is the evidence. | `com.appsflyer:af-android-sdk` |
| Mixpanel | Product analytics, `MixpanelAPI.getInstance`. | `com.mixpanel.android:mixpanel-android` |
| Amplitude | Product analytics. Legacy SDK: `com.amplitude.api` (`Amplitude.getInstance()`, `AmplitudeClient`); current Kotlin SDK: `com.amplitude.android` + `com.amplitude.core`. | legacy `com.amplitude:android-sdk`; current `com.amplitude:analytics-android` |
| Segment | Customer data platform, `Analytics.with(context)`; detection-only in the registry (no neutralization targets yet). | `com.segment.analytics.android:analytics` |
| Braze (formerly Appboy) | Engagement/push. `com.braze` (v4+), `com.appboy` (legacy). | `com.braze:android-sdk-ui` |
| CleverTap | Engagement/analytics, `CleverTapAPI.getDefaultInstance`; account id in the `CLEVERTAP_ACCOUNT_ID` meta-data. | `com.clevertap.android:clevertap-android-sdk` |
| Flurry | Yahoo analytics, `new FlurryAgent.Builder()…build(context, apiKey)` (legacy `FlurryAgent.init` / `onStartSession`); detection-only in the registry. | `com.flurry.android:analytics` |
| Singular, AppMetrica, Google Analytics (legacy), Google Tag Manager, Firebase Crashlytics, Sentry, Bugsnag, Backtrace, Facebook SDK, TikTok Business SDK, ByteDance APM Insight, SYBO in-house analytics | See their registry entries (`--list-sdks`). | — |
