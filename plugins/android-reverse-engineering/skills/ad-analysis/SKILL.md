---
name: ad-analysis
description: Detect and analyze advertising SDKs in decoded (apktool) or decompiled (jadx) Android apps. Covers every ads / ads_mediation entry of the SDK registry plus consent frameworks — e.g. AdMob, Unity Ads, IronSource/LevelPlay, AppLovin/MAX, Meta Audience Network, Vungle/Liftoff, InMobi, Chartboost, Pangle, Mintegral, Fyber/DT, BidMachine, Moloco, Google UMP — with HIGH/MEDIUM/LOW/NONE confidence. Extracts ad formats (banner, interstitial, rewarded, native), mediation setup, ad unit IDs, and consent/privacy frameworks.
trigger: find ads|ad analysis|advertising SDK|detect ads|ad network|AdMob|Unity Ads|IronSource|AppLovin|Facebook ads|Meta Audience Network|Vungle|InMobi|Chartboost|Pangle|Mintegral|Fyber|DT Exchange|BidMachine|Moloco|Amazon APS|PubNative|Ogury|BIGO Ads|Kidoz|Google UMP|consent framework|mediation|ad format|rewarded ad|interstitial ad|banner ad
---

# Ad Analysis

Detect and analyze advertising SDKs embedded in decompiled Android applications. Produces a structured report covering ad network identification, ad formats used, mediation configuration, ad unit/placement IDs, and consent/privacy framework compliance.

## Prerequisites

This skill operates on an **already decoded or decompiled** app. If the app has not been decompiled yet, use the `android-reverse-engineering` skill first:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/decompile.sh <apk-file>
```

Accepted inputs (the script detects the layout and logs it on stderr as `[INFO] layout: …`):
- an **apktool** decode directory (`AndroidManifest.xml` + `smali*/`, e.g. from `sdk-neutralizer/scripts/decode-apk.sh`): the most precise input, with real package names;
- a **jadx** output directory (`sources/` + `resources/`) or its `sources/` directory (jadx can rename whole package trees, e.g. ironSource into `com/json/` or `org/json/`; the audit maps them back with package aliases);
- a jadx XAPK output directory (`<split>/sources/`);
- any other source tree, with `--manifest-path <AndroidManifest.xml>`.

**jq**: `find-ads.sh` needs jq >= 1.6 to read the SDK registry. Without it the script exits 2 and prints `INSTALL_REQUIRED:jq`: run `bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/install-dep.sh jq` and retry. On Windows use `find-ads.ps1` (Windows PowerShell 5.1, same options, no jq needed; from Bash under WSL, convert the paths before leaving the current directory and run from a Windows directory in a subshell: `S=$(wslpath -w "<script.ps1>"); I=$(wslpath -w "<input-dir>"); (cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$S" "$I" <options>)`; from Git Bash on native Windows, where there is no `/mnt/c` and no `wslpath`: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "<script.ps1>")" "$(cygpath -w "<input-dir>")" <options>`, with no `cd`). `<script.ps1>` is `${CLAUDE_PLUGIN_ROOT}/skills/ad-analysis/scripts/find-ads.ps1`.

## Workflow

### Phase 1: Verify the Input

Confirm that the input directory exists and contains code (`.smali`, `.java` or `.kt` files).

**Action**: Check the provided directory path.

- If the user provides a path, verify it exists and contains code files
- If no decoded or decompiled tree is available, instruct the user to run `/decompile` first
- The AndroidManifest.xml contains ad-related Activities, Services, meta-data (APPLICATION_ID, sdk keys), and the AD_ID permission; the script finds it by itself for the layouts above

### Phase 2: Detect SDKs, Formats, and Mediation

Run the ad detection script. It audits **every ads / ads_mediation entry of the SDK registry** (`skills/sdk-neutralizer/registry/*.json`) plus the consent entries; `--list-sdks` prints the live list.

**Action**: Start with the confidence summary, then the full report.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/ad-analysis/scripts/find-ads.sh <input-dir> --summary
bash ${CLAUDE_PLUGIN_ROOT}/skills/ad-analysis/scripts/find-ads.sh <input-dir> --all
```

For targeted searches:
```bash
# Single SDK: prints its Identity, role sections and also "<SDK> — References"
# (listeners, AdRequest.Builder, callbacks... named in app code; --full lifts the 50-row limit)
bash ${CLAUDE_PLUGIN_ROOT}/skills/ad-analysis/scripts/find-ads.sh <input-dir> --admob
bash ${CLAUDE_PLUGIN_ROOT}/skills/ad-analysis/scripts/find-ads.sh <input-dir> --unity
bash ${CLAUDE_PLUGIN_ROOT}/skills/ad-analysis/scripts/find-ads.sh <input-dir> --sdk moloco      # any ads/consent sdk_id
bash ${CLAUDE_PLUGIN_ROOT}/skills/ad-analysis/scripts/find-ads.sh <input-dir> --list-sdks      # sdk_id, category, legacy flag, neutralizable, packages, audit_only_packages

# Specific aspects
bash ${CLAUDE_PLUGIN_ROOT}/skills/ad-analysis/scripts/find-ads.sh <input-dir> --formats    # cross-SDK format detection + ad unit / placement ids
bash ${CLAUDE_PLUGIN_ROOT}/skills/ad-analysis/scripts/find-ads.sh <input-dir> --mediation   # mediation adapters, adapter classes, waterfall
bash ${CLAUDE_PLUGIN_ROOT}/skills/ad-analysis/scripts/find-ads.sh <input-dir> --consent     # UMP, TCF, COPPA, SDK-specific opt-out (tracker entries too, as [sdk_id/trackers])
```

Options:
- SDK filters: `--admob --unity --ironsource --applovin --facebook` (Meta Audience Network) `--vungle --inmobi --chartboost --pangle --mintegral`, `--sdk <sdk_id>` (repeatable)
- Aspects: `--formats --mediation --consent --manifest --entrypoints`; `--all` = everything (default)
- Output: text (default), `--summary`, `--tsv` (machine-readable), `--json` (report v2); the last three always cover every ads/consent entry and ignore the filters
- `--full`, `--no-hints`, `--manifest-path F`, `--registry DIR`; options are case-insensitive and take one or two dashes

**Confidence levels** (the same rules for every SDK; generic words such as `banner` or a bare `.loadAd(` never count):

| Level | Meaning |
|---|---|
| HIGH | SDK code present (a file under one of its registry packages) and its marker class, when the registry declares one |
| MEDIUM | SDK code without the declared marker class (`detail=partial`), or AndroidManifest declarations only (`detail=manifest-only`) |
| LOW | no SDK code: app-code references, ad unit id prefixes (`ca-app-pub-`) or endpoint domains only |
| NONE | not detected |

Rows end with the SDKs they name, e.g. `[google-admob/init]`; `ref` = class reference, a trailing `?` = import-scoped instance call. `neutralizable=no (detection-only)` marks registry entries without `targets` (e.g. BIGO Ads, Kidoz): the sdk-neutralizer cannot stub them yet; see `${CLAUDE_PLUGIN_ROOT}/skills/sdk-neutralizer/references/registry-backlog.md`.

Parse the output to identify:
- Which ad SDKs are present
- Which ad formats are used (banner, interstitial, rewarded, native, app-open)
- Whether mediation is set up and which SDK is the mediator
- Consent framework presence

For each detected SDK, read the surrounding code to extract:

1. **Initialization**: Where and how is the SDK initialized? Extract app ID/SDK key
2. **Ad formats**: Which formats are implemented? Extract ad unit/placement IDs
3. **Mediation**: Is this SDK a mediator or a mediated network? Which adapters are present?
   - See `${CLAUDE_PLUGIN_ROOT}/skills/ad-analysis/references/mediation-patterns.md`
4. **Ad format details**: For each format, understand the load/show lifecycle
   - See `${CLAUDE_PLUGIN_ROOT}/skills/ad-analysis/references/ad-format-patterns.md`
5. **Consent**: Does the app implement UMP, TCF, or SDK-specific consent?

### Phase 2b: Identify Active Entry Points

Distinguish which ad SDKs the app calls directly vs which are only present as passive mediation dependencies.

**Action**: Run the entry point detection.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/ad-analysis/scripts/find-ads.sh <input-dir> --entrypoints
```

This lists ad SDK calls and class references **only from app code**: files owned by a registry SDK (its packages, namespaces and adapters, jadx-renamed trees included) or by a known library (`library_roots` of `_audit-shared.json`) are excluded. The results reveal which SDKs the app actively uses. Code of an SDK without a registry entry is not known to the audit and appears as app code: check the package of each row (and `registry-backlog.md`).

**Analysis**:

1. Compare the entry point results with the full SDK detection from Phase 2
2. For each detected SDK, classify it as:
   - **Active**: the app code calls its init/load/show methods directly
   - **Passive**: its code is present only inside library packages (mediation adapters)
3. Determine the ad architecture:
   - **Single mediator**: the app calls only 1 ad SDK (e.g., AdMob `MobileAds.initialize()`), all others are passive adapter dependencies
   - **Multiple direct**: the app calls 2+ ad SDKs directly (manual ad network brokerage)
   - **Hybrid**: the app calls a mediator for some formats and additional SDKs directly for others

See `${CLAUDE_PLUGIN_ROOT}/skills/ad-analysis/references/mediation-patterns.md` — "Active vs Passive SDKs" section for detailed patterns.

### Phase 3: Produce Report

Generate a structured ad analysis report.

**Report format:**

```markdown
# Ad Analysis Report — <app name>

## Summary

| Ad Network | Confidence | Role | Formats | Ad Unit IDs | Consent | Neutralizable |
|---|---|---|---|---|---|---|
| AdMob | HIGH | Mediator | Banner, Interstitial, Rewarded | ca-app-pub-XXX/YYY, ... | UMP ✓ | yes |
| Unity Ads | HIGH | Mediated | Interstitial, Rewarded | (via mediation) | — | yes |
| IronSource | HIGH | Mediated | Rewarded | (via mediation) | — | yes |
| BIGO Ads | HIGH | Mediated | — | — | — | no (detection-only) |

## Ad Architecture

- **Type**: Single mediator / Multiple direct / Hybrid
- **Active entry points** (called from app code):
  - `MobileAds.initialize()` — `com/example/app/AdManager.java:28`
  - `InterstitialAd.load()` — `com/example/app/GameActivity.java:112`
- **Passive SDKs** (present only as mediation adapter dependencies):
  - Unity Ads, IronSource, AppLovin, Meta AN — invoked only via `com.google.ads.mediation.*` adapters

```
App code ──→ AdMob (mediator)
               ├──→ Google Ads (direct)
               ├──→ UnityAdapter ──→ Unity Ads SDK  [passive]
               ├──→ IronSourceAdapter ──→ IS SDK    [passive]
               └──→ AppLovinAdapter ──→ AL SDK      [passive]
```

## Mediation Setup

- **Primary mediator**: AdMob
- **Strategy**: Hybrid (bidding + waterfall)
- **Mediated networks**: Unity Ads, IronSource, AppLovin, Meta AN
- **Adapter classes found**: list

## Ad Formats by Placement

### Banner
- **SDK**: AdMob (direct)
- **Size**: BANNER (320×50)
- **Ad unit**: `ca-app-pub-XXXXX/YYYYY`
- **Location**: `MainActivity.java:45` — bottom of screen
- **Auto-refresh**: yes

### Interstitial
- **SDK**: AdMob (mediated to Unity, IronSource)
- **Ad unit**: `ca-app-pub-XXXXX/ZZZZZ`
- **Load location**: `GameActivity.java:112`
- **Show trigger**: level complete (`onLevelComplete()`)

### Rewarded
- **SDK**: AdMob (mediated)
- **Ad unit**: `ca-app-pub-XXXXX/WWWWW`
- **Reward**: 50 coins (`onUserEarnedReward`)
- **Show trigger**: "Watch ad for coins" button

## Ad Unit / Placement IDs

| ID | Format | SDK | Location |
|---|---|---|---|
| `ca-app-pub-XXXXX/YYYYY` | Banner | AdMob | MainActivity.java:45 |
| `ca-app-pub-XXXXX/ZZZZZ` | Interstitial | AdMob | GameActivity.java:112 |

## Privacy & Consent

- **UMP / Funding Choices**: ✓ implemented in `ConsentActivity.java`
- **TCF v2**: ✓ (IABTCF_ keys in SharedPreferences)
- **COPPA**: tagForChildDirectedTreatment = false
- **AD_ID permission**: declared in manifest
- **Per-network consent**: setHasUserConsent called for [list]

## Neutralizer Coverage

- **Detected but not neutralizable** (registry entries without targets): BIGO Ads, ...
```

## References

- `${CLAUDE_PLUGIN_ROOT}/skills/sdk-neutralizer/registry/*.json` — the single source of SDK packages, marker classes, manifest names, domains and APIs (`find-ads.sh --list-sdks` for the list)
- `${CLAUDE_PLUGIN_ROOT}/skills/ad-analysis/references/ad-sdk-catalog.md` — Short notes per known SDK and Gradle coordinates
- `${CLAUDE_PLUGIN_ROOT}/skills/ad-analysis/references/mediation-patterns.md` — Mediation layers, waterfall vs bidding, adapter identification
- `${CLAUDE_PLUGIN_ROOT}/skills/ad-analysis/references/ad-format-patterns.md` — Banner, interstitial, rewarded, native, app-open patterns
