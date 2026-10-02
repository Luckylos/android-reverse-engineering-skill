# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Claude Code Skill (plugin) for Android reverse engineering, API extraction, and privacy auditing. It provides four skills:
- **android-reverse-engineering**: 5-phase workflow — dependency verification, APK/XAPK/JAR/AAR decompilation (jadx and/or Fernflower), manifest/structure analysis, call flow tracing, and HTTP API endpoint extraction
- **tracker-analysis**: 4-phase workflow — detect analytics/tracker SDKs (every tracker entry of the SDK registry: Firebase, Adjust, AppsFlyer, Mixpanel, Amplitude, Segment, Braze, CleverTap, Flurry, Singular, ...; HIGH/MEDIUM/LOW/NONE confidence), analyze init/events/user ID/consent, report data exfiltration endpoints
- **ad-analysis**: 3-phase workflow — detect ad SDKs (every ads/ads_mediation entry of the SDK registry: AdMob, Unity, IronSource, AppLovin, Meta AN, Vungle, InMobi, Chartboost, Pangle, Mintegral, ...; plus consent frameworks), map ad formats and mediation setup, report privacy/consent
- **sdk-neutralizer**: 6-phase workflow — decode APK, identify tracker/ad SDK entry points, neutralize by replacing smali method bodies with stubs, disable manifest components, rebuild and sign APK for enterprise sideloading

## Repository Structure

- `.claude-plugin/marketplace.json` — Marketplace catalog entry
- `plugins/android-reverse-engineering/.claude-plugin/plugin.json` — Plugin manifest
- `plugins/android-reverse-engineering/commands/decompile.md` — `/decompile` slash command
- `plugins/android-reverse-engineering/commands/find-trackers.md` — `/find-trackers` slash command
- `plugins/android-reverse-engineering/commands/find-ads.md` — `/find-ads` slash command
- `plugins/android-reverse-engineering/commands/neutralize.md` — `/neutralize` slash command
- `plugins/android-reverse-engineering/skills/android-reverse-engineering/` — Core RE skill (5-phase workflow, references, scripts)
- `plugins/android-reverse-engineering/skills/tracker-analysis/` — Tracker/analytics SDK detection skill (4-phase workflow, references, find-trackers.sh/.ps1: thin wrappers of the sdk-audit engine)
- `plugins/android-reverse-engineering/skills/ad-analysis/` — Advertising SDK detection skill (3-phase workflow, references, find-ads.sh/.ps1: thin wrappers of the sdk-audit engine)
- `plugins/android-reverse-engineering/skills/sdk-neutralizer/` — SDK neutralization skill (6-phase workflow, references incl. `registry-backlog.md`, decode-apk.sh/.ps1, detect-protection.sh/.ps1, detect-adwrapper.sh/.ps1, neutralize.sh, registry-scan.py, rebuild-apk.sh/.ps1, check-neutralize-deps.sh/.ps1, registry-query.sh/.jq/.ps1 + registry-lib.ps1 (registry reader), sdk-audit.sh/.ps1 (audit engine of find-trackers / find-ads))
- `plugins/android-reverse-engineering/skills/sdk-neutralizer/registry/` — SDK registry, the single source of SDK knowledge (55 entry files: 49 neutralizable entries defining neutralization targets, manifest components, protected patterns — including `consent-umptcf.json`, a code-injection entry for UMP/IAB-TCF consent — plus 6 detection-only entries; `_schema.json`, `_audit-shared.json` + `_audit-shared.schema.json`)
- `tests/` — dev-only test harness (not shipped with the plugin): `tests/run.sh`, see "Tests" below

## Key Scripts

Core scripts under `plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/`:

```bash
# Check installed dependencies
bash scripts/check-deps.sh

# Install a dependency (auto-detects OS/package manager)
bash scripts/install-dep.sh <dep>   # e.g., jadx, vineflower, dex2jar

# Install ALL neutralizer dependencies at once (java, apktool, apkeditor, build-tools, zip; jq as an optional soft-fail extra);
# build-tools (pinned Android SDK Build-Tools 36.0.0) needs the user's explicit license acceptance
bash scripts/install-dep.sh neutralize-all --accept-android-sdk-license

# Decompile an APK/JAR/AAR/XAPK
bash scripts/decompile.sh [--engine jadx|fernflower|both] [--deobf] [--no-res] [-o outdir] <file>

# Search decompiled source for API calls
bash scripts/find-api-calls.sh <source-dir> [--retrofit|--okhttp|--volley|--urls|--auth|--all]
```

Tracker analysis script under `plugins/android-reverse-engineering/skills/tracker-analysis/scripts/`:

```bash
# Audit tracker/analytics SDKs (every tracker entry of the registry; needs jq >= 1.6, else exit 2 + INSTALL_REQUIRED:jq)
# <input-dir>: apktool decode dir, jadx output dir, its sources/, jadx XAPK dir, or any tree (+ --manifest-path)
bash find-trackers.sh <input-dir> [--firebase|--adjust|--appsflyer|--mixpanel|--amplitude|--segment|--braze|--clevertap|--flurry]
    [--sdk <sdk_id>]... [--generic|--endpoints|--manifest|--entrypoints|--all] [--summary|--tsv|--json]
    [--manifest-path F] [--registry DIR] [--full] [--no-hints]
bash find-trackers.sh --list-sdks          # sdk_id, category, legacy_flag, neutralizable, packages (.packages), audit_only_packages (detection.extra_packages, never neutralized)
# Windows twin (PowerShell 5.1, no jq): find-trackers.ps1, same option tokens
```

Ad analysis script under `plugins/android-reverse-engineering/skills/ad-analysis/scripts/`:

```bash
# Audit advertising SDKs + consent frameworks (every ads/ads_mediation/consent entry of the registry)
bash find-ads.sh <input-dir> [--admob|--unity|--ironsource|--applovin|--facebook|--vungle|--inmobi|--chartboost|--pangle|--mintegral]
    [--sdk <sdk_id>]... [--formats|--mediation|--consent|--manifest|--entrypoints|--all] [--summary|--tsv|--json]
    [--manifest-path F] [--registry DIR] [--full] [--no-hints]
bash find-ads.sh --list-sdks
# Windows twin: find-ads.ps1
# Confidence: HIGH = SDK code present (+ marker class when declared); MEDIUM = code without the
# declared marker, or AndroidManifest only; LOW = app-code references / endpoints / id prefixes only;
# NONE. --summary/--tsv/--json cover the whole group and ignore filters (--json = report v2).
```

SDK neutralizer scripts under `plugins/android-reverse-engineering/skills/sdk-neutralizer/scripts/`:

```bash
# Check neutralization dependencies (including apktool >= 2.9.0, Python 3.6+ optional;
# APKEditor required when <input> is a split bundle; reports zipalign -P 16 support)
bash check-neutralize-deps.sh [<input>]

# Decode APK, or merge a split bundle (XAPK/APKM/APKS/dir) with APKEditor then decode
# (writes .merged-from-splits.json; --keep-splits = deprecated base-only decode + .xapk-origin/)
bash decode-apk.sh <file.apk|file.xapk|file.apkm|file.apks|dir> [-o <decoded-dir>] [--keep-splits]

# Detect anti-tamper / integrity / licensing protection (PairIP, LVL, packers/RASP from
# APKiD signatures) — detection only, never bypassed; run automatically by decode-apk,
# always exits 0; PROTECTION_DETECTED:<id>:<category>:<confidence>:<evidence> +
# PROTECTION_SUMMARY:<none|integrity|license|hardener|signature-vm>
bash detect-protection.sh <decoded-dir>

# Detect a publisher's in-house ad/analytics mediation wrapper (a layer that drives the
# network ad SDKs, or serves house/WebView ads, on the app's behalf — e.g. com.rovio.beacon,
# guru.ads.fusion) that per-network registry neutralization can miss — detection only, never
# modified/removed; run automatically by decode-apk, always exits 0; excludes known SDKs
# (registry, minus entries flagged "in_house_wrapper": true) + common libs;
# ADWRAPPER_DETECTED:<package>:<confidence>:<evidence> + ADWRAPPER_SUMMARY:<none|candidate>
bash detect-adwrapper.sh <decoded-dir>

# Scan decoded APK against SDK registry (generates targets-file + manifest-components-file)
# Depth: 1=entry_points only, 2=+ad_operations, 3=+deep_patterns
python3 registry-scan.py <decoded-dir> --registry <registry-path> --depth 1|2|3 --category ads|trackers|all --output-dir <decoded-dir>

# Neutralize SDK entry points in decoded APK (dry-run first)
# Registry-driven mode (preferred):
bash neutralize.sh <decoded-dir> --no-builtin-targets --targets-file <decoded-dir>/registry-targets.txt --manifest-components-file <decoded-dir>/registry-manifest.txt [--dry-run] [--package <path>]
# Fallback (builtin targets):
bash neutralize.sh <decoded-dir> [--ads|--trackers|--all] [--dry-run] [--backup] [--no-manifest] [--targets-file <file>] [--replay] [--no-save-manifest]

# Rebuild and sign a single APK (zipalign -P 16 / -p — required for stored .so with
# extractNativeLibs=false; alignment check of all stored entries; ABI warning;
# stable user-level debug key ~/.config/android-re/neutralizer-debug.keystore);
# a deprecated --keep-splits dir (.xapk-origin/) is reassembled into an XAPK instead
bash rebuild-apk.sh <decoded-dir> [--auto-keystore|--debug-key|--keystore <file>] [-o <output>] [--no-sign] [--zipalign|--no-zipalign]
```

Windows: `check-neutralize-deps.ps1`, `decode-apk.ps1`, `detect-protection.ps1`, `detect-adwrapper.ps1` and `rebuild-apk.ps1` mirror the bash scripts (PowerShell 5.1, `-Output`/`-KeepSplits`/`-AutoKeystore`...); `neutralize.sh` and `registry-scan.py` still require bash + python3 (WSL/Git Bash) for now. `APKEDITOR_JAR` overrides the APKEditor JAR location on both platforms.

SDK registry under `plugins/android-reverse-engineering/skills/sdk-neutralizer/registry/`:

- 55 SDK entry files (49 neutralizable + 6 detection-only: segment, flurry, tiktok-business, apm-insight, bigo-ads, kidoz) + `_schema.json` schema definition + `_audit-shared.json` (cross-SDK audit data: category groups, legacy `--<sdk>` flags, `library_roots`, ad format tables, hints) with its `_audit-shared.schema.json`
- `targets` is optional: an entry **without** `targets` is *detection-only* — the audit reports it, `registry-scan.py` skips it (one-line guard), `detect-adwrapper` still excludes its `packages`. To make it neutralizable, add `targets` to that entry (never a second entry for the same SDK)
- Covers: AdMob, Unity Ads, IronSource, AppLovin, Meta AN, Vungle, InMobi, Chartboost, Pangle, BidMachine, Smaato, PubNative, Ogury, Fyber, Amazon APS, Facebook, Firebase Analytics, Firebase Crashlytics, AppsFlyer, Adjust, Braze, CleverTap, Guru Fusion, Mintegral, Mixpanel, MobileFuse, Moloco, PubMatic, TradPlus, Tapjoy, Yandex Ads, Google Tag Manager, AppMetrica, AdColony, Microsoft App Center, Google UMP / IAB TCF consent (and more: `find-ads.sh --list-sdks` / `find-trackers.sh --list-sdks`); detection-only: Segment, Flurry, TikTok Business, ByteDance APM Insight, BIGO Ads, Kidoz
- Each JSON defines: packages, entry_points, ad_operations, deep_patterns, manifest_components, protected_patterns; a method target may specify either `stub` (trivial no-op/constant return) or `inject` (code injection)
- **Consent neutralization** (`category: consent`, `consent-umptcf.json`) is a distinct capability: instead of stubbing, it INJECTS code that suppresses the Google UMP / IAB TCF consent dialog and writes a reject-all TCF v2.2 state (gdprApplies=1, all-zero consent + legitimate-interest keys, a decode-verified reject-all `IABTCF_TCString`) to the default SharedPreferences, so TCF-honoring SDKs self-limit. The inject kind travels on the targets-file line as an optional third `:`-field; `neutralize.sh` emits the injected smali. See `skills/sdk-neutralizer/references/consent-neutralization.md`. It complements (does not replace) per-SDK stubbing.
- `registry-scan.py` consumes these JSONs to generate neutralization targets
- The optional `detection` object (`extra_packages`, `exclude_packages`, `namespace_roots`, `adapter_packages`, `marker_classes`, `manifest_names`, `domains`, `id_prefixes`, `apis`) is read **only** by the audit (`sdk-audit.sh/.ps1` via `registry-query`); `registry-scan.py` and `neutralize.sh` never read it, and `detect-adwrapper` reads only `packages`
- Read the registry from scripts with `registry-query.sh rows|shared|packages` (jq >= 1.6; `packages` has a POSIX-awk fallback) or, in PowerShell, `registry-lib.ps1` (`Get-RegistryRows/-Shared/-Packages`)
- Known gaps (SDKs without entry, detection-only entries, detection facts not promoted to neutralization data): `skills/sdk-neutralizer/references/registry-backlog.md`; its generated part is refreshed with `bash tests/tools/registry-gaps.sh --write`
- Other copies of SDK knowledge that do not read the registry yet (to unify in later steps; listed in `registry-backlog.md` section C): the builtin fallback catalog of `neutralize.sh`, `third_party_hosts.txt`, `fingerprint.sh` SDK markers, `recover-kotlin-names.sh` `SKIP_PREFIXES`, `registry-scan.py` `KNOWN_LIBRARY_PACKAGES`, and detect-adwrapper's `NETWORK_ROOTS` / `COMMON_ROOTS` (frozen; sh == ps1 enforced by `tests/unit/t_network_roots.sh`)

## Architecture

**Plugin structure follows Claude Code skill conventions:**
- `skills/<name>/SKILL.md` defines the skill's workflow and capabilities
- `commands/<name>.md` defines slash commands with YAML frontmatter
- `scripts/` contains executable bash utilities invoked by the skill
- `references/` contains in-depth technical documentation the skill consults

**Script conventions:**
- Exit codes: 0 = success, 1 = error, 2 = manual action needed
- `check-deps.sh` outputs machine-readable `INSTALL_REQUIRED:` and `INSTALL_OPTIONAL:` lines
- `decompile.sh` handles XAPK by extracting the archive and decompiling each APK separately
- `${CLAUDE_PLUGIN_ROOT}` references the plugin root directory; `FERNFLOWER_JAR_PATH` for custom JAR location

**Decompiler strategy:**
- jadx: default for APKs (fast, handles resources natively)
- Fernflower/Vineflower: better Java output for complex code, requires dex2jar for APK input
- `--engine both`: runs both in parallel and compares output quality

## Tests

There is no build step. A dev-only harness lives in `tests/` (not shipped with the plugin; see `tests/README.md`):

```bash
tests/run.sh                 # quick (~1-2 min): registry lint + unit tests + sh/ps1 parity on fixtures
tests/run.sh full            # + golden (registry-scan / detect-adwrapper byte-identical to the frozen baseline),
                             #   snapshot, corpus ground truth, bash 3.2, perf (~50 min with PowerShell + corpus)
tests/run.sh lint unit       # selected suites; tests/run.sh t_cli = one test
tests/run.sh --expect-pass lint golden   # a SKIP of these counts as FAIL
bash tests/tools/registry-gaps.sh --check   # generated part of registry-backlog.md up to date
```

Optional requirements (a missing one gives SKIP, never FAIL): Windows PowerShell 5.1 reachable from WSL (`ARE_PS`), a bash 3.2 binary (`BASH32`), the APK corpus and its golden baselines next to the repo (`ARE_CORPUS`, `ARE_JADX`, `ARE_PRISTINE`, `ARE_GOLD`), `gawk`/`mawk`/`busybox` for the awk matrix, python `jsonschema` for schema validation in the lint.

## Versioning

The plugin version is declared in **three** places across two files that **must always be kept in sync**:
- `.claude-plugin/marketplace.json` → `metadata.version` (marketplace metadata)
- `.claude-plugin/marketplace.json` → `plugins[0].version` (marketplace catalog entry)
- `plugins/android-reverse-engineering/.claude-plugin/plugin.json` → `version` (plugin manifest)

Claude Code reads the version from `plugin.json` with priority — if that file has a stale version, `/plugin` will show the old number even if `marketplace.json` is updated. **Always bump all three together; never update only one file.**

**When to bump:** suggest a version bump whenever a PR or significant change lands (new skill, new script, new SDK registry entries, workflow changes) — minor bump (`1.x.0`) for new features/important PRs, patch bump (`1.x.y`) for fixes and docs-only changes. Keep `master` and long-lived feature branches on the same version after merging between them, so the version fields don't conflict on the next merge.

## Conventions

- Line endings are LF (enforced via `.gitattributes` for WSL/Windows compatibility)
- Scripts target Bash 4.0+ and support Linux (apt/dnf/pacman) and macOS (Homebrew); `install-dep.sh`, `check-neutralize-deps.sh`, `decode-apk.sh`, `rebuild-apk.sh`, `detect-adwrapper.sh`, `registry-query.sh`, `sdk-audit.sh` and the `find-trackers.sh` / `find-ads.sh` wrappers are written to also run on macOS's stock bash 3.2 with BSD tools (no `declare -A`, `mapfile`, `${x,,}`; awk is POSIX only: no gawk extensions, checked under `gawk --posix`, mawk and busybox awk; no `grep -P`, no `\s`)
- `.sh`/`.ps1` pairs must keep feature parity; `.ps1` scripts target Windows PowerShell 5.1 (no PS7-only syntax)
- **Platform priority: Linux first, then macOS, then Windows.** Develop and validate every new feature in the `.sh` script first (keeping it macOS-compatible: bash 3.2, BSD tools, POSIX awk); only when that work is complete, align the `.ps1` twin and verify functional equivalence (e.g. `tests/parity/`). Parity is mandatory, but it is the last step, not a parallel track
- Scripts fall back to user-local installs (`~/.local/`) when sudo is unavailable; `install-dep.sh` must run as the user (it refuses sudo for per-user targets and calls sudo itself only for system packages)
- jq (>= 1.6) is required only by `find-trackers.sh` / `find-ads.sh` (exit 2 + `INSTALL_REQUIRED:jq`); the checkers report it as `INSTALL_OPTIONAL:jq`; it is never needed on Windows (the `.ps1` scripts use `ConvertFrom-Json`), and no `.ps1` checker prints an `INSTALL_*:jq` line. No Python at runtime for the audit
- PowerShell libraries (`registry-lib.ps1`, `sdk-audit.ps1`) contain only function definitions: no `param()` block, no global/script state other than the documented `$script:SdkAuditExit` result, dot-sourced inside the caller's function; they return their output on the pipeline (the audit report as one string, exit code in `$script:SdkAuditExit`). `.ps1` sources are ASCII-only; sorting and comparisons are ordinal
- Registry rules: **no regular expressions in the registry** (literals only: packages, classes, hosts, prefixes, method names); **`detection` is not neutralization** (adding a detection fact never changes what gets stubbed; promoting it to `packages` / `targets` / `manifest_components` is a separate change reviewed against the registry-scan golden); new entries follow `_schema.json` and keep `"packages": [` / `sdk_id` / `in_house_wrapper` once each at top level, one string per line (the awk fallback parser relies on it)
- **Every registry change**: run `tests/run.sh quick` (lint + unit) and `tests/run.sh golden` (registry-scan and detect-adwrapper must stay byte-identical unless the change is meant to alter neutralization), and refresh `registry-backlog.md` with `bash tests/tools/registry-gaps.sh --write`
