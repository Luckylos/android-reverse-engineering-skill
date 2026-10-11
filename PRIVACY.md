# Privacy Policy

_Last updated: 2026-10-11_

The **android-reverse-engineering** plugin for Claude Code is an open-source set of
instructions and local scripts. It does not include any server, account, or
telemetry operated by the author.

## Data the plugin collects

None. The plugin does not collect, store, or transmit personal data, usage
statistics, or the files you analyze.

## Local processing

Everything the plugin does to your files happens on your machine, with locally
installed tools (jadx, Vineflower/Fernflower, dex2jar, Apktool, APKEditor,
smali/baksmali, jq, the Android SDK build-tools, Java):

- **Decompiling and searching** (`/decompile`, `find-api-calls`): APK, XAPK,
  JAR, and AAR files are decompiled into a directory you choose.
- **Tracker and ad audits** (`/find-trackers`, `/find-ads`): read the decoded
  or decompiled tree and the SDK registry shipped with the plugin. They make
  no network requests.
- **SDK neutralization** (`/neutralize`): decodes the APK, patches the decoded
  copy, rebuilds, aligns and signs a **new** APK next to it
  (`<decoded-dir>-neutralized.apk` by default), and writes a
  `neutralize-manifest.json` describing what changed. The original APK is
  never modified. Optional `.smali.bak` backups are created only with
  `--backup`.

The scripts do not read credentials, tokens, or API keys from your environment
or files. The "auth" search options only scan the decompiled source you point
them at for authentication-related strings. The only secrets they handle are
keystore passwords that you pass yourself (`--store-pass`, `--key-pass`),
which are used locally for signing and never sent anywhere.

### Signing key

By default the neutralizer signs rebuilt APKs with a debug key that it creates
once on your machine and then reuses, so successive builds install over each
other:

- Linux and macOS: `${XDG_CONFIG_HOME:-~/.config}/android-re/neutralizer-debug.keystore`
- Windows: `%APPDATA%\android-re\neutralizer-debug.keystore`

This is a debug key with the well-known password `android`. It is not a
secret and is not meant for apps you publish; use `--keystore` to sign with
your own key. Deleting the file is safe: a new key is created next time (APKs
signed with the old key then need to be uninstalled before the new build can
be installed).

## Network access

The only network requests the plugin's scripts make are dependency downloads,
and only when you run `install-dep.sh` / `install-dep.ps1` (Claude Code asks
for your approval each time):

- GitHub (`api.github.com`, `github.com`): release metadata and archives for
  jadx, Vineflower, dex2jar, Apktool, APKEditor, smali/baksmali, and jq;
- Bitbucket (`bitbucket.org`): fallback download for Apktool;
- Google (`dl.google.com`): Android SDK build-tools (`zipalign`, `apksigner`)
  and platform-tools (`adb`), only when you explicitly accept the Android SDK
  License Agreement;
- your system package manager (for example Homebrew, apt, dnf, pacman,
  winget, scoop, or Chocolatey) for Java and a few system packages (`zip`,
  and `adb`/`apksigner`/`jq` where no direct download is used).

Per-user tools are installed into your home directory (`~/.local/bin`,
`~/.local/share/...`) and need no administrator rights. `sudo` is used only
by the script itself for system packages, and the script refuses to run under
`sudo`. If `sudo` cannot be used non-interactively, the script prints the
exact command for you to run instead.

Downloads of APKEditor, the Android build-tools, and jq are checked against
pinned SHA-256 hashes; the other tools are fetched from their official
release pages.

These requests go directly to those services and are subject to their own
privacy policies. No data about you or your analyzed files is included.

The tools themselves are third-party software under their own licenses and
terms; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Claude

Like any Claude Code plugin, the content Claude reads while using this plugin
(for example decompiled source) is processed by Claude under Anthropic's terms
and privacy policy, not by the plugin author.

## Contact

Questions or concerns: open an issue at
https://github.com/SimoneAvogadro/android-reverse-engineering-skill/issues
