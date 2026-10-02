# Ad SDK Catalog

The SDK registry `skills/sdk-neutralizer/registry/*.json` is the **single source** of the packages, marker classes, manifest names, endpoint domains, ad unit id prefixes, APIs and mediation adapter packages used to detect ad SDKs (the `detection` object of each entry, plus `packages` and `targets`); cross-SDK knowledge (ad format tables, hints, library roots) lives in `registry/_audit-shared.json`. This page no longer lists them, so it cannot drift from what the scripts do.

- **Live list**: `bash ${CLAUDE_PLUGIN_ROOT}/skills/ad-analysis/scripts/find-ads.sh --list-sdks` (TSV: `sdk_id`, `category`, `legacy_flag`, `neutralizable`, `packages`). Every entry of the categories ads, ads_mediation and consent is audited.
- **One entry in detail**: `jq . ${CLAUDE_PLUGIN_ROOT}/skills/sdk-neutralizer/registry/<sdk_id>.json`.
- **Adding an SDK**: add a registry entry (`<sdk_id>.json`, see `_schema.json`). `targets` is optional: an entry without it is *detection-only* (the audit sees it, `registry-scan.py` and `neutralize.sh` ignore it). Known gaps are tracked in `skills/sdk-neutralizer/references/registry-backlog.md`.

## Notes per SDK (documentation only)

| SDK | Notes | Gradle |
|---|---|---|
| AdMob / Google Mobile Ads | `MobileAds.initialize`; app id in the `com.google.android.gms.ads.APPLICATION_ID` meta-data, ad unit ids `ca-app-pub-…`. Its mediation adapters live under `com.google.ads.mediation`. `com.google.android.gms.ads.identifier` (advertising id) is a Play services helper, not AdMob. | `com.google.android.gms:play-services-ads` |
| Unity Ads | `UnityAds.initialize/load/show`; also `com.unity3d.services`, the SCAR adapters `com.unity3d.scar` and the protobuf `gatewayprotocol`. | `com.unity3d.ads:unity-ads` |
| IronSource / LevelPlay | Mediator (`IronSource.init`, LevelPlay `LevelPlay*` classes); adapters under `com.ironsource.adapters`. jadx often renames the whole tree (`com/json/`, `org/json/`). | `com.ironsource.sdk:mediationsdk` |
| AppLovin / MAX | Mediator (`AppLovinSdk`, `Max*Ad`); sdk key in the `applovin.sdk.key` meta-data; adapters under `com.applovin.mediation.adapters`. | `com.applovin:applovin-sdk` |
| Meta Audience Network | `AudienceNetworkAds.initialize`, package `com.facebook.ads` (the registry entry `meta-audience-network`; `--facebook`). A second, shaded copy ships as a DEX in the assets. | `com.facebook.android:audience-network-sdk` |
| Vungle / Liftoff | `com.vungle.warren` (legacy, `Vungle.init`), `com.vungle.ads` (v7+: `VungleAds`, `InterstitialAd`, `RewardedAd`, `BannerAd`, `VungleBannerView`). | `com.vungle:vungle-ads` |
| InMobi | `InMobiSdk.init`, `InMobiBanner` / `InMobiInterstitial` / `InMobiNative`; ad activity `com.inmobi.ads.rendering.InMobiAdActivity`. | `com.inmobi.monetization:inmobi-ads` |
| Chartboost | v9: `Chartboost.startWithAppId` + `com.chartboost.sdk.ads.*`; legacy v8 static `cacheInterstitial` / `showInterstitial` / `showRewardedVideo`. | `com.chartboost:chartboost-sdk` |
| Pangle (ByteDance) | v5+: `PAGSdk.init`, `PAG*Ad`, plus `com.pgl.ssdk`, `com.bykv.vk`, `com.bytedance.adsdk`; legacy: `TTAdSdk.init`, `TTAdNative`, `TT*Ad` (`com.bytedance.sdk.openadsdk`). | `com.pangle.global:ads-sdk` |
| Mintegral | `com.mbridge.msdk` (`MBridgeSDKFactory` in `com.mbridge.msdk.out`, `MB*Handler`, `MBBannerView`); legacy package `com.mintegral`. | `com.mbridge.msdk.oversea:*` |
| Google UMP (consent) | `UserMessagingPlatform`, `ConsentInformation`, `ConsentForm`; reported by `find-ads --consent` (`Consent — Google UMP / Funding Choices`). | `com.google.android.ump:user-messaging-platform` |
| AdColony, Amazon APS, BidMachine, Fyber / DT Exchange, HyprMX, maio, myTarget, MobileFuse, Moloco, Ogury, PubMatic, PubNative / HyBid, Smaato, SuperAwesome, Tapjoy, TradPlus, Yandex Ads, Appodeal, Guru Fusion, Rovio Beacon, BIGO Ads, Kidoz | See their registry entries (`--list-sdks`). | — |
