---
description: Detect and analyze analytics/tracker SDKs in decoded (apktool) or decompiled (jadx) Android apps. Covers every tracker entry of the SDK registry (analytics, attribution, crash reporting, social) — e.g. Firebase Analytics, Adjust, AppsFlyer, Mixpanel, Amplitude, Segment, Braze, CleverTap, Flurry, Singular, AppMetrica, Crashlytics, Facebook SDK, TikTok Business — with HIGH/MEDIUM/LOW/NONE confidence. Extracts initialization patterns, event logging, user identification, consent mechanisms, and data exfiltration endpoints.
trigger: find trackers|tracker analysis|analytics SDK|detect trackers|privacy analysis trackers|telemetry SDK|Firebase Analytics|Adjust SDK|AppsFlyer|Mixpanel|Amplitude|Segment|Braze|CleverTap|Flurry|Singular|AppMetrica|Crashlytics|what trackers|which analytics|tracking SDK
---

# Tracker Analysis

Detect and analyze analytics/tracker SDKs embedded in decompiled Android applications. Produces a structured privacy report covering SDK identification, initialization, event logging, user identification, consent handling, and known data exfiltration endpoints.

## Prerequisites

This skill operates on an **already decoded or decompiled** app. If the app has not been decompiled yet, use the `android-reverse-engineering` skill first:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/decompile.sh <apk-file>
```

Accepted inputs (the script detects the layout and logs it on stderr as `[INFO] layout: …`):
- an **apktool** decode directory (`AndroidManifest.xml` + `smali*/`, e.g. from `sdk-neutralizer/scripts/decode-apk.sh`): the most precise input, with real package names;
- a **jadx** output directory (`sources/` + `resources/`) or its `sources/` directory (jadx can rename whole package trees, e.g. ironSource into `com/json/`; the audit maps them back with package aliases);
- a jadx XAPK output directory (`<split>/sources/`);
- any other source tree, with `--manifest-path <AndroidManifest.xml>`.

**jq**: `find-trackers.sh` needs jq >= 1.6 to read the SDK registry. Without it the script exits 2 and prints `INSTALL_REQUIRED:jq`: run `bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/install-dep.sh jq` and retry. On Windows use `find-trackers.ps1` (Windows PowerShell 5.1, same options, no jq needed; from Bash under WSL, convert the paths before leaving the current directory and run from a Windows directory in a subshell: `S=$(wslpath -w "<script.ps1>"); I=$(wslpath -w "<input-dir>"); (cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$S" "$I" <options>)`; from Git Bash on native Windows, where there is no `/mnt/c` and no `wslpath`: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "<script.ps1>")" "$(cygpath -w "<input-dir>")" <options>`, with no `cd`). `<script.ps1>` is `${CLAUDE_PLUGIN_ROOT}/skills/tracker-analysis/scripts/find-trackers.ps1`.

## Workflow

### Phase 1: Verify the Input

Confirm that the input directory exists and contains code (`.smali`, `.java` or `.kt` files).

**Action**: Check the provided directory path.

- If the user provides a path, verify it exists and contains code files
- If no decoded or decompiled tree is available, instruct the user to run `/decompile` first
- The AndroidManifest.xml (apktool root, or jadx `resources/`) contains tracker-relevant metadata; the script finds it by itself for the layouts above

### Phase 2: Broad Detection Sweep

Run the tracker detection script. It audits **every tracker entry of the SDK registry** (`skills/sdk-neutralizer/registry/*.json`, categories analytics, attribution, crash_reporting and social); `--list-sdks` prints the live list.

**Action**: Start with the confidence summary, then the full report.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/tracker-analysis/scripts/find-trackers.sh <input-dir> --summary
bash ${CLAUDE_PLUGIN_ROOT}/skills/tracker-analysis/scripts/find-trackers.sh <input-dir> --all
```

For targeted searches on a specific SDK (an SDK chosen this way is always printed, `status=NOT FOUND` when absent):
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/tracker-analysis/scripts/find-trackers.sh <input-dir> --firebase
bash ${CLAUDE_PLUGIN_ROOT}/skills/tracker-analysis/scripts/find-trackers.sh <input-dir> --adjust --mixpanel
bash ${CLAUDE_PLUGIN_ROOT}/skills/tracker-analysis/scripts/find-trackers.sh <input-dir> --sdk singular      # any tracker sdk_id
bash ${CLAUDE_PLUGIN_ROOT}/skills/tracker-analysis/scripts/find-trackers.sh <input-dir> --list-sdks        # sdk_id, category, legacy flag, neutralizable, packages, audit_only_packages
```

Options:
- SDK filters: `--firebase --adjust --appsflyer --mixpanel --amplitude --segment --braze --clevertap --flurry`, `--sdk <sdk_id>` (repeatable)
- Aspects: `--generic` (generic cross-SDK calls: hints, never evidence), `--endpoints`, `--manifest`, `--entrypoints` (calls and class references from app code only); `--all` = everything (default)
- Output: text (default), `--summary`, `--tsv` (machine-readable), `--json` (report v2); the last three always cover every tracker entry and ignore the filters
- `--full` (no 50-row limit on `<SDK> — References`), `--no-hints`, `--manifest-path F`, `--registry DIR`
- Options are case-insensitive and take one or two dashes (`--sdk=x`, `--sdk:x` work)

**Confidence levels** (the same rules for every SDK; generic method names never count):

| Level | Meaning |
|---|---|
| HIGH | SDK code present (a file under one of its registry packages) and its marker class, when the registry declares one |
| MEDIUM | SDK code without the declared marker class (`detail=partial`), or AndroidManifest declarations only (`detail=manifest-only`) |
| LOW | no SDK code: app-code references, known endpoint domains or id prefixes only (`detail=app-refs+endpoints…`) |
| NONE | not detected |

Reading the text report: every SDK at LOW or above gets `<SDK> — Identity` (first row `# confidence=… status=… neutralizable=yes|no (detection-only) detail=…`; package and marker rows use line `0`, meaning "not a line match"), one section per role with call sites in app code (`— Initialization`, `— Event Tracking`, `— User Identity`, `— Consent`, `— Configuration`), `— Manifest`, `— Endpoints` and `— References`. Rows end with the SDKs they name, e.g. `[firebase-analytics/init]`; `ref` = class reference, a trailing `?` = import-scoped instance call (receiver type inferred from the imports). Empty sections are not detections.

`neutralizable=no (detection-only)` marks registry entries without `targets` (e.g. Segment, Flurry, TikTok Business, APM Insight): the sdk-neutralizer cannot stub them yet; see `${CLAUDE_PLUGIN_ROOT}/skills/sdk-neutralizer/references/registry-backlog.md`.

### Phase 3: Deep Semantic Analysis

For each detected SDK, perform a thorough analysis following the patterns in the reference documents.

**For each SDK found, trace these in order:**

1. **Initialization**: How is the SDK initialized? Where is the API key/app ID? Is it hardcoded or loaded from config?
   - Read the initialization code and extract credentials
   - Check `AndroidManifest.xml` for meta-data entries
   - See `${CLAUDE_PLUGIN_ROOT}/skills/tracker-analysis/references/tracker-init-patterns.md`

2. **Event Logging**: What events are tracked? Are they standard SDK events or custom?
   - List all event names (both string literals and constants)
   - Note what data is attached to each event (parameters, properties)
   - Look for revenue/purchase tracking

3. **User Identification**: How are users identified across sessions?
   - Find `setUserId`, `identify`, `onUserLogin` calls
   - Check what user properties are set (email, name, custom attributes)
   - Look for cross-device identification

4. **Consent & Opt-out**: Does the app implement consent management for this SDK?
   - Find opt-out/opt-in calls
   - Check for GDPR compliance (forget-me, data deletion)
   - Check for consent gating (is analytics enabled only after consent?)

5. **Data Exfiltration**: Where does the data go?
   - Identify endpoints from `${CLAUDE_PLUGIN_ROOT}/skills/tracker-analysis/references/data-exfiltration-patterns.md`
   - Check for custom endpoints or proxy/relay configurations
   - Look for batch upload patterns

### Phase 4: Produce Report

Generate a structured tracker analysis report.

**Report format:**

```markdown
# Tracker Analysis Report — <app name>

## Summary

| SDK | Confidence | Version hint | Init location | Events tracked | User ID | Consent | Neutralizable |
|-----|-----------|-------------|---------------|----------------|---------|---------|---------------|
| Firebase Analytics | HIGH | (from gradle/manifest) | Application.onCreate | 12 custom + standard | setUserId | setConsent ✓ | yes |
| Adjust | HIGH | — | MainActivity | 3 events | — | gdprForgetMe ✓ | yes |
| Flurry | HIGH | — | (no app-code call) | — | — | — | no (detection-only) |
| ... | | | | | | | |

## Detailed Analysis

### Firebase Analytics

- **Initialization**: `FirebaseAnalytics.getInstance()` in `MyApp.java:34`
- **API Key / App ID**: `google_app_id` = `1:123456:android:abc` (from strings.xml)
- **Events tracked**:
  - `select_content` (standard) — item_id, item_name
  - `purchase_complete` (custom) — amount, currency, product_id
  - ...
- **User identification**: `setUserId("...")` called in `LoginViewModel.java:78`
- **User properties**: `subscription_tier`, `app_version`
- **Consent**: `setAnalyticsCollectionEnabled(false)` in `ConsentManager.java:22`, toggled based on user preference
- **Endpoints**: `app-measurement.com` (standard, no custom relay)

### [Next SDK...]

## Privacy Summary

- **Total SDKs detected**: N (HIGH / MEDIUM; LOW listed separately as leftovers or references)
- **Not covered by the sdk-neutralizer**: detection-only SDKs (from the `--summary` footer)
- **SDKs with consent gating**: list
- **SDKs without consent gating**: list (⚠️)
- **User data shared**: email, user ID, device ID, location, ...
- **Known endpoint domains**: list of all domains data is sent to
```

## References

- `${CLAUDE_PLUGIN_ROOT}/skills/sdk-neutralizer/registry/*.json` — the single source of SDK packages, marker classes, manifest names, domains and APIs (`find-trackers.sh --list-sdks` for the list)
- `${CLAUDE_PLUGIN_ROOT}/skills/tracker-analysis/references/tracker-sdk-catalog.md` — Short notes per known SDK and Gradle coordinates
- `${CLAUDE_PLUGIN_ROOT}/skills/tracker-analysis/references/tracker-init-patterns.md` — Init calls, event logging, user ID, consent per SDK
- `${CLAUDE_PLUGIN_ROOT}/skills/tracker-analysis/references/data-exfiltration-patterns.md` — Endpoints, proxy patterns, batch upload
