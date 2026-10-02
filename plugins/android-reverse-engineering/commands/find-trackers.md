---
allowed-tools: Bash, Read, Glob, Grep, Write
description: Detect and analyze tracker/analytics SDKs in a decoded or decompiled Android app
user-invocable: true
argument-hint: <path to the apktool or jadx output directory (or its sources/)>
argument: path to the apktool or jadx output directory, or its sources/ directory (optional)
---

# /find-trackers

Detect and analyze analytics/tracker SDKs in a decoded (apktool) or decompiled (jadx) Android app.

## Instructions

You are starting the tracker analysis workflow. Follow these steps:

### Step 0: jq (bash only)

`find-trackers.sh` reads the SDK registry with **jq >= 1.6**. If the script exits with code 2 and prints `INSTALL_REQUIRED:jq`, install it and retry:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/install-dep.sh jq
```

On Windows use the PowerShell twin `find-trackers.ps1` instead: it reads the registry natively and never needs jq. `allowed-tools` is `Bash` only, so launch it from Bash through Windows PowerShell 5.1 with Windows paths. The conversion depends on which Bash you are in (`uname -s` prints `Linux` under WSL, `MINGW64_NT-...` under Git Bash).

Under WSL, convert both paths with `wslpath -w` first (a relative `$INPUT_DIR` resolves against the current directory), then run PowerShell from a Windows directory inside a subshell, so the shell's working directory does not change:

```bash
S=$(wslpath -w "${CLAUDE_PLUGIN_ROOT}/skills/tracker-analysis/scripts/find-trackers.ps1"); I=$(wslpath -w "$INPUT_DIR"); (cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$S" "$I" --summary)
```

Under Git Bash (Claude Code on native Windows, where jq is usually missing), there is no `/mnt/c` and no `wslpath`: convert with `cygpath -w` and do not `cd`:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "${CLAUDE_PLUGIN_ROOT}/skills/tracker-analysis/scripts/find-trackers.ps1")" "$(cygpath -w "$INPUT_DIR")" --summary
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

Start with the confidence-scored overview of every tracker entry of the SDK registry:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/tracker-analysis/scripts/find-trackers.sh "$INPUT_DIR" --summary
```

Then the full text report (sections `==== <Section> ====`, rows `path:line:text`):

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/tracker-analysis/scripts/find-trackers.sh "$INPUT_DIR" --all
```

The report prints, for every SDK at level LOW or above, `<SDK> — Identity` (a `# confidence=… status=… neutralizable=…` row plus the package / marker-class rows; line `0` means "not a line match"), one section per role with call sites in app code (`<SDK> — Initialization`, `— Event Tracking`, `— User Identity`, `— Consent`, ...), `<SDK> — Manifest`, `<SDK> — Endpoints` and `<SDK> — References` (app-code rows that name an SDK class; 50 rows, `--full` for all). Then the aspect sections (`Known Tracker Endpoints`, `AndroidManifest — …`, `Generic — …`) and `Entry Points — Tracker SDK calls from app code`.

Useful options:
- `--firebase --adjust --appsflyer --mixpanel --amplitude --segment --braze --clevertap --flurry`: one SDK (combinable); an SDK chosen this way is always printed, with `status=NOT FOUND` when absent.
- `--sdk <sdk_id>`: any tracker entry of the registry (repeatable). `--list-sdks` lists them (TSV: `sdk_id category legacy_flag neutralizable packages audit_only_packages`; `packages` are the entry's `.packages`, the ones registry-scan neutralizes when `neutralizable=yes`; `audit_only_packages` are `detection.extra_packages`, identity for the audit only and never neutralized).
- `--generic`, `--endpoints`, `--manifest`, `--entrypoints`: one aspect only.
- `--tsv` (machine-readable rows) and `--json` (report v2, `schema_version: 2`) always cover every tracker entry and ignore the filters.
- `--no-hints` drops the informational hint rows.

### Step 3: Analyze each detected SDK

For each SDK at HIGH or MEDIUM, perform deep analysis:

1. **Read the initialization code** — find where the SDK is set up, extract API keys/app IDs
2. **Catalog tracked events** — list all event names and their parameters
3. **Check user identification** — find setUserId/identify calls, what user data is collected
4. **Verify consent handling** — check if the app gates analytics on user consent
5. **Identify data endpoints** — known domains (the registry's `detection.domains`) and any custom relay/proxy

Use the reference documents in `${CLAUDE_PLUGIN_ROOT}/skills/tracker-analysis/references/` for SDK-specific patterns.

### Step 3b: Read the confidence levels

The level comes from the evidence, never from generic method names:

- **HIGH** — the SDK's own code is in the app (a file under one of its registry packages) and, when the registry declares one, its marker class is present. The SDK is integrated.
- **MEDIUM** — SDK code without the declared marker class (`detail=partial`: stripped or partial copy), or only AndroidManifest declarations (`detail=manifest-only`). Check the manifest rows and the identity rows.
- **LOW** — no SDK code: only app-code references to SDK classes, known endpoint domains or id prefixes (`detail=app-refs+endpoints…`). Usually a leftover or a string; read the rows before reporting it.
- **NONE** — not detected.

Generic calls (`.track(`, `.logEvent(`, `.identify(` on unknown receivers) are never evidence: they appear only as `Generic — …` hint rows. A trailing `?` in a row annotation (`[firebase-analytics/event?]`) marks an import-scoped instance call: the receiver's type was inferred from the file's imports.

`neutralizable=no (detection-only)` means the registry entry has no `targets`: the sdk-neutralizer cannot stub that SDK yet (see `skills/sdk-neutralizer/references/registry-backlog.md`). The `--summary` footer lists these as "Detected but NOT neutralized".

### Step 4: Produce report

Generate a structured report with:
- **Summary table**: SDK name, confidence, init location, event count, user ID method, consent status
- **Per-SDK detail**: initialization, events, user data, consent, endpoints
- **Privacy summary**: total SDKs, consent coverage, user data shared, endpoint domains, SDKs the neutralizer does not cover

Refer to `${CLAUDE_PLUGIN_ROOT}/skills/tracker-analysis/SKILL.md` for the full report format.

### Step 5: Offer next steps

Tell the user what they can do next:
- **Deep-dive a specific SDK**: "I can trace the full data flow for Firebase Analytics"
- **Check data exfiltration**: "I can search for proxy/relay patterns and custom endpoints"
- **Analyze ad SDKs**: "Run `/find-ads` to analyze advertising SDKs too"
- **Neutralize**: "Run `/neutralize` to stub the detected trackers for enterprise deployment"
- **Export report**: "I can save this report as a markdown file"
