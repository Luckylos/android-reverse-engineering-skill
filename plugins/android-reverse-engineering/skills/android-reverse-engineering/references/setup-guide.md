# Setup Guide: Dependencies for Android Reverse Engineering

## Java JDK 17+

jadx requires Java 17 or later.

### Ubuntu / Debian

```bash
sudo apt update
sudo apt install openjdk-17-jdk
```

### Fedora

```bash
sudo dnf install java-17-openjdk-devel
```

### Arch Linux

```bash
sudo pacman -S jdk17-openjdk
```

### macOS (Homebrew)

```bash
brew install openjdk@17
```

After installation on macOS, follow the symlink instructions printed by Homebrew, or add to your shell profile:

```bash
export PATH="/opt/homebrew/opt/openjdk@17/bin:$PATH"
```

### Verify

```bash
java -version
# Should show version 17.x or higher
```

---

## jadx

jadx is the Java decompiler used to convert APK/JAR/AAR files to readable Java source.

### Option 1: GitHub Releases (recommended)

1. Go to <https://github.com/skylot/jadx/releases/latest>
2. Download the `jadx-<version>.zip` file (not the source archive)
3. Extract and add to PATH:

```bash
unzip jadx-*.zip -d ~/jadx
export PATH="$HOME/jadx/bin:$PATH"
# Add the export line to your ~/.bashrc or ~/.zshrc for persistence
```

### Option 2: Homebrew (macOS / Linux)

```bash
brew install jadx
```

### Option 3: Build from source

```bash
git clone https://github.com/skylot/jadx.git
cd jadx
./gradlew dist
# Binaries will be in build/jadx/bin/
export PATH="$(pwd)/build/jadx/bin:$PATH"
```

### Verify

```bash
jadx --version
```

---

## Fernflower / Vineflower (optional, recommended)

Fernflower is the JetBrains Java decompiler. It produces better output than jadx on complex Java constructs, lambdas, and generics. [Vineflower](https://github.com/Vineflower/vineflower) is the actively maintained community fork with published releases — prefer it over upstream Fernflower.

### Option 1: Vineflower from GitHub Releases (recommended)

1. Go to <https://github.com/Vineflower/vineflower/releases/latest>
2. Download `vineflower-<version>.jar`
3. Place it and set the environment variable:

```bash
mkdir -p ~/vineflower
mv vineflower-*.jar ~/vineflower/vineflower.jar
export FERNFLOWER_JAR_PATH="$HOME/vineflower/vineflower.jar"
# Add the export to ~/.bashrc or ~/.zshrc for persistence
```

### Option 2: Build Fernflower from source

```bash
git clone https://github.com/JetBrains/fernflower.git
cd fernflower
./gradlew jar
# Produces: build/libs/fernflower.jar
export FERNFLOWER_JAR_PATH="$(pwd)/build/libs/fernflower.jar"
```

### Option 3: Homebrew (Vineflower)

```bash
brew install vineflower
```

### Verify

```bash
java -jar "$FERNFLOWER_JAR_PATH" --version
```

> **Note**: Fernflower only works on JVM bytecode (JAR, class files). For APK/DEX files, you also need **dex2jar** (see below) as an intermediate conversion step.

---

## dex2jar (optional, needed for Fernflower on APK files)

Converts Android DEX bytecode to standard Java JAR files.

### GitHub Releases

1. Go to <https://github.com/ThexXTURBOXx/dex2jar/releases/latest>
2. Download and extract:

```bash
unzip dex-tools-*.zip -d ~/dex2jar
export PATH="$HOME/dex2jar:$PATH"
```

### Homebrew

```bash
brew install dex2jar
```

### Verify

```bash
d2j-dex2jar --help
```

### Usage

```bash
# Convert APK (or DEX) to JAR
d2j-dex2jar -f -o output.jar app.apk

# Then decompile with Fernflower
java -jar vineflower.jar output.jar decompiled/
```

---

## Optional Tools

### apktool

Useful for decoding resources (XML layouts, drawables) that jadx sometimes handles poorly.

```bash
# Ubuntu/Debian
sudo apt install apktool

# macOS
brew install apktool

# Manual: https://apktool.org/docs/install
```

### APKEditor

Used by the SDK neutralizer to merge XAPK/APKM/APKS split APKs into one APK before decoding.

```bash
# Pinned release, SHA-256 verified, installed to ~/.local/share/apkeditor/APKEditor.jar
bash scripts/install-dep.sh apkeditor
# Windows: .\scripts\install-dep.ps1 apkeditor
# Custom location: export APKEDITOR_JAR=/path/to/APKEditor.jar
```

### Android SDK Build-Tools (zipalign, apksigner)

Required by the SDK neutralizer to page-align native libraries (`zipalign -P 16` needs build-tools 35+) and sign APKs. Distro packages are too old (Debian's `zipalign` has no `-P`, its `apksigner` does not align).

```bash
# Pinned 36.0.0 from dl.google.com, SHA-256 verified, into ~/.local/share/android-sdk
# (uses sdkmanager instead when ANDROID_HOME/ANDROID_SDK_ROOT has one).
# Licensed under the Android SDK License: https://developer.android.com/studio/terms
bash scripts/install-dep.sh build-tools --accept-android-sdk-license
# Windows: .\scripts\install-dep.ps1 build-tools -AcceptAndroidSdkLicense
```

### jq (SDK audit, bash only)

`find-trackers.sh` and `find-ads.sh` read the SDK registry with **jq >= 1.6** and exit 2 with `INSTALL_REQUIRED:jq` without it. `check-deps.sh` and `check-neutralize-deps.sh` report it as `INSTALL_OPTIONAL:jq` only (`/decompile` and the neutralizer never need it: `detect-adwrapper.sh` has a built-in fallback parser).

```bash
# Uses brew on macOS; apt/dnf/pacman only when sudo works; otherwise a pinned jq 1.8.2
# static binary (SHA-256 verified) into ~/.local/bin/jq
bash scripts/install-dep.sh jq
```

| OS | Command |
|---|---|
| Ubuntu / Debian | `sudo apt install jq` (Ubuntu 18.04 / Debian 10 ship jq 1.5: too old, use `install-dep.sh jq`) |
| Fedora | `sudo dnf install jq` |
| Arch Linux | `sudo pacman -S jq` |
| macOS | `brew install jq` (the stock `jq-1.7.1-apple` of recent macOS also works) |
| Other distros | `install-dep.sh jq` (static binary) |
| Windows | **not needed**: `find-trackers.ps1` / `find-ads.ps1` and the other `.ps1` scripts read the registry with `ConvertFrom-Json` (`install-dep.ps1 jq` just says so). Under Git Bash or WSL, the `.sh` scripts need jq like on Linux |

If `install-dep.sh jq` exits 2 saying that an older jq comes first on `PATH`, put `~/.local/bin` first (`export PATH="$HOME/.local/bin:$PATH"`, also in the shell profile) or remove the old jq.

**PowerShell 5.1 output note**: `> out.txt` inside Windows PowerShell 5.1 writes UTF-16. Capture the `.ps1` output from Bash (`powershell.exe -File … > out.txt`), or in PowerShell with `| Out-File -Encoding utf8 out.txt`.

### adb (Android Debug Bridge)

Useful for pulling APKs directly from a connected Android device.

```bash
# Ubuntu/Debian
sudo apt install adb

# macOS
brew install android-platform-tools
```

Pull an APK from a device:

```bash
# List installed packages
adb shell pm list packages | grep <keyword>

# Get APK path
adb shell pm path com.example.app

# Pull the APK
adb pull /data/app/com.example.app-xxxx/base.apk ./app.apk
```

---

## Troubleshooting

| Problem | Solution |
|---|---|
| `jadx: command not found` | Ensure the jadx `bin/` directory is in your `$PATH` |
| `Error: Could not find or load main class` | Java is missing or wrong version — verify with `java -version` |
| jadx runs out of memory on large APKs | Increase heap: `jadx -Xmx4g -d output app.apk` or set `JAVA_OPTS="-Xmx4g"` |
| Decompiled code has many `// Error` comments | Try `--show-bad-code` to see partial output, or use `--deobf` for obfuscated apps |
| Fernflower hangs on a method | Use `-mpm=60` to set a 60-second timeout per method |
| Fernflower JAR not found | Set `FERNFLOWER_JAR_PATH` env variable to the full path of the JAR |
| dex2jar fails with `ZipException` | The APK may have a non-standard ZIP structure — try `jadx` instead |
