---
allowed-tools: Bash, Read, Glob, Grep, Write
description: Detect and analyze advertising SDKs in a decoded or decompiled Android app
user-invocable: true
argument-hint: <path to the apktool or jadx output directory (or its sources/)>
argument: path to the apktool or jadx output directory, or its sources/ directory (optional)
---

# /find-ads

Detect and analyze advertising SDKs (and consent frameworks) in a decoded (apktool) or decompiled (jadx) Android app.

## Instructions

You are starting the ad analysis workflow. Follow these steps:

### Step 0: jq (bash only)

`find-ads.sh` reads the SDK registry with **jq >= 1.6**. If the script exits with code 2 and prints `INSTALL_REQUIRED:jq`, install it and retry:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/install-dep.sh jq
```

On Windows use the PowerShell twin `find-ads.ps1` instead: it reads the registry natively and never needs jq. `allowed-tools` is `Bash` only, so launch it from Bash through Windows PowerShell 5.1 with Windows paths. The conversion depends on which Bash you are in (`uname -s` prints `Linux` under WSL, `MINGW64_NT-...` under Git Bash).

Under WSL, convert both paths with `wslpath -w` first (a relative `$INPUT_DIR` resolves against the current directory), then run PowerShell from a Windows directory inside a subshell, so the shell's working directory does not change:

```bash
S=$(wslpath -w "${CLAUDE_PLUGIN_ROOT}/skills/ad-analysis/scripts/find-ads.ps1"); I=$(wslpath -w "$INPUT_DIR"); (cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$S" "$I" --summary)
```

Under Git Bash (Claude Code on native Windows, where jq is usually missing), there is no `/mnt/c` and no `wslpath`: convert with `cygpath -w` and do not `cd`:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "${CLAUDE_PLUGIN_ROOT}/skills/ad-analysis/scripts/find-ads.ps1")" "$(cygpath -w "$INPUT_DIR")" --summary
```

The `.ps1` takes the same option tokens (`--summary`, `-summary`, `-Summary` are the same option). Do not redirect its output with `>` inside PowerShell 5.1 (it writes UTF-16); capture it from Bash or with `| Out-File -Encoding utf8`.

### Step 1: Get the input directory

If the user provided a path as an argument, use that. Otherwise, ask the user for the path to the decoded or decompiled app.

Accepted inputs (the script picks the layout itself and logs it on stderr as `[INFO]`):
- an **apktool** decode directory (`AndroidManifest.xml` + `smali*/`; the most precise input: real package names, no jadx renames);
- a **jadx** output directory (`sources/` + `resources/`), or its `sources/` directory;
- a jadx XAPK output directory (`<split>/sources/`);
- any other source tree (pass `--manifest-path <AndroidManifest.xml>` for the manifest evidence).

If no decoded or decompiled tree exists yet, tell the user to run `/decompile` first on their APK/XAPK file (or `decode-apk.sh` of the sdk-neutralizer skill for an apktool decode).

### Step 2: Run broad detection

Start with the confidence-scored overview of every ads, ads_mediation and consent entry of the SDK registry:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/ad-analysis/scripts/find-ads.sh "$INPUT_DIR" --summary
```

Then the full text report (sections `==== <Section> ====`, rows `path:line:text`):

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/ad-analysis/scripts/find-ads.sh "$INPUT_DIR" --all
```

For every SDK at level LOW or above the report prints `<SDK> — Identity` (a `# confidence=… status=… neutralizable=…` row plus the package / marker-class rows; line `0` means "not a line match"), one section per role with call sites in app code (`— Initialization`, `— Ad Loading`, `— Ad Showing`, `— Consent`, ...), `— Manifest`, `— Ad Unit IDs` and `— References` (app-code rows that name an SDK class: listeners, `AdRequest.Builder`, callbacks; 50 rows, `--full` for all). Then the aspect sections: `Cross-SDK — All <Format> Patterns`, `Cross-SDK — Ad Unit / Placement IDs`, `Mediation — <Mediator> Mediation Adapters`, `Mediation — Adapter Classes`, `Mediation — Waterfall & Bidding Configuration`, `Consent — …`, `AndroidManifest — …`, and `Entry Points — Ad SDK calls from app code`.

Useful options:
- `--admob --unity --ironsource --applovin --facebook --vungle --inmobi --chartboost --pangle --mintegral`: one SDK (combinable; `--facebook` = Meta Audience Network). An SDK chosen this way is always printed, with `status=NOT FOUND` when absent, and includes its `— References` section.
- `--sdk <sdk_id>`: any ads/consent entry of the registry (repeatable). `--list-sdks` lists them (TSV: `sdk_id category legacy_flag neutralizable packages audit_only_packages`; `packages` are the entry's `.packages`, the ones registry-scan neutralizes when `neutralizable=yes`; `audit_only_packages` are `detection.extra_packages`, identity for the audit only and never neutralized).
- `--formats`, `--mediation`, `--consent`, `--manifest`, `--entrypoints`: one aspect only. `--consent` also lists the consent APIs of tracker entries (e.g. Adjust `gdprForgetMe`, Facebook `setDataProcessingOptions`), annotated `[sdk_id/trackers]`.
- `--tsv` (machine-readable rows) and `--json` (report v2, `schema_version: 2`) always cover every ads/consent entry and ignore the filters.
- `--no-hints` drops the informational hint rows (ad unit / waterfall / TCF token matches).

### Step 3: Analyze detected SDKs and identify active entry points

For each SDK at HIGH or MEDIUM:

1. **Identify the role** — is it the primary mediator or a mediated network?
2. **Extract ad unit/placement IDs** — find all ID strings
3. **Map ad formats** — which formats (banner, interstitial, rewarded, native, app-open) are implemented?
4. **Trace the load/show lifecycle** — where is each ad loaded and when is it shown?
5. **Check mediation setup** — if mediation is detected, identify all adapters and the waterfall/bidding strategy

**Distinguish active vs passive SDKs** with the entry point section:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/ad-analysis/scripts/find-ads.sh "$INPUT_DIR" --entrypoints
```

It lists ad SDK calls and class references **only from app code**: every file owned by a registry SDK or by a known library (`library_roots`) is excluded, and so are jadx-renamed SDK trees (e.g. ironSource decompiled into `com/json/` or `org/json/`). Each row ends with the SDKs it names, e.g. `[google-admob/init]` or `[unity-ads/ref]`. Code of an SDK that has no registry entry yet (e.g. DT Ignite `com/digitalturbine`, see `registry-backlog.md`) is not known to the audit and shows up here as if it were app code: check the package of each row. Compare these results with the full detection from Step 2:

- SDKs that appear in `--entrypoints` output are **actively called** by the app
- SDKs detected in Step 2 but absent from `--entrypoints` are **passive dependencies** (mediation adapters only)
- Determine the **ad architecture**: Single mediator, Multiple direct, or Hybrid

Use the reference documents in `${CLAUDE_PLUGIN_ROOT}/skills/ad-analysis/references/` for SDK-specific patterns.

### Step 3b: Read the confidence levels

The level comes from the evidence, never from generic class or method names:

- **HIGH** — the SDK's own code is in the app (a file under one of its registry packages) and, when the registry declares one, its marker class is present. The SDK is integrated.
- **MEDIUM** — SDK code without the declared marker class (`detail=partial`), or only AndroidManifest declarations (`detail=manifest-only`). Check the manifest rows and the identity rows.
- **LOW** — no SDK code: only app-code references, ad unit id prefixes (`ca-app-pub-`) or endpoint domains. Read the rows before reporting it (e.g. AdMob's advertising-id helper `gms.ads.identifier` alone is not AdMob).
- **NONE** — not detected.

Generic ad words (`banner`, `interstitial`, a bare `.loadAd(`) are never evidence: they appear only as hint rows. A trailing `?` in a row annotation (`[applovin/load?]`) marks an import-scoped instance call: the receiver's type was inferred from the file's imports.

`neutralizable=no (detection-only)` means the registry entry has no `targets`: the sdk-neutralizer cannot stub that SDK yet (see `skills/sdk-neutralizer/references/registry-backlog.md`). The `--summary` footer lists these as "Detected but NOT neutralized", plus `Mediation adapters: N` and `Consent framework: <sdk_id> <LEVEL>`.

### Step 4: Produce report

Generate a structured report with:
- **Summary table**: ad network, confidence, role (mediator/mediated/active/passive), formats, ad unit IDs, consent
- **Ad architecture**: type (Single mediator / Multiple direct / Hybrid), active entry points with file:line, passive SDK list, ASCII diagram
- **Mediation setup**: primary mediator, strategy, mediated networks, adapter classes
- **Ad formats by placement**: for each format — SDK, ad unit, load/show location, trigger
- **Ad unit ID table**: all discovered IDs with format, SDK, and source location
- **Privacy & consent**: UMP, TCF, COPPA, AD_ID permission, per-network consent
- **Neutralizer coverage**: detected SDKs that are detection-only in the registry

Refer to `${CLAUDE_PLUGIN_ROOT}/skills/ad-analysis/SKILL.md` for the full report format.

### Step 5: Offer next steps

Tell the user what they can do next:
- **Deep-dive a specific ad network**: "I can trace the full integration for AdMob"
- **Analyze mediation waterfall**: "I can map the exact network priority order"
- **Check trackers**: "Run `/find-trackers` to analyze analytics/tracker SDKs too"
- **Neutralize**: "Run `/neutralize` to stub the detected ad SDKs for enterprise deployment"
- **Export report**: "I can save this report as a markdown file"
