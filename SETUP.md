# BitDrop — Development Environment Setup

Your system: **Ubuntu 24.04 LTS** | Java 21 ✅ | ADB ✅ | 65 GB free disk | 23 GB RAM

## What's Missing

| Tool | Status | Required For |
|------|--------|-------------|
| Android SDK (cmdline-tools, platform 35, build-tools) | ❌ Not installed | Building spike-audio APK |
| Android NDK | ❌ Not installed | Rust cross-compilation (Phase 1+) |
| Rust (rustup + cargo) | ❌ Not installed | Core engine (Phase 1+) |
| Flutter SDK | ❌ Not installed | UI layer (Phase 1+) |

## Step 1: Android SDK (Required NOW for Spike 1)

```bash
# Download Android command-line tools
mkdir -p ~/Android/Sdk/cmdline-tools
cd ~/Android/Sdk/cmdline-tools
wget https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
unzip commandlinetools-linux-11076708_latest.zip
mv cmdline-tools latest

# Add to PATH (add these to ~/.bashrc too)
export ANDROID_HOME=~/Android/Sdk
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools

# Accept licenses and install required packages
yes | sdkmanager --licenses
sdkmanager "platforms;android-35" "build-tools;35.0.0" "platform-tools"
```

## Step 2: Build & Install Spike 1

```bash
cd ~/Desktop/BitDrop/spike-audio

# Gradle wrapper will download itself
chmod +x gradlew 2>/dev/null || gradle wrapper --gradle-version 8.7
./gradlew assembleDebug

# Connect your S10+ via USB (enable USB Debugging in Developer Options)
adb install app/build/outputs/apk/debug/app-debug.apk
```

## Step 3: Rust (Needed for Phase 1, can install now)

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source ~/.cargo/env

# Android cross-compilation targets
rustup target add aarch64-linux-android armv7-linux-androideabi

# Install Android NDK (needed for Rust cross-compilation)
sdkmanager "ndk;27.0.12077973"
```

## Step 4: Flutter (Needed for Phase 1, can install now)

```bash
# Install via snap (recommended for Ubuntu)
sudo snap install flutter --classic
flutter doctor
```

## Step 5: Linux Desktop Audio (Required for Linux local playback)
```bash
sudo apt-get update && sudo apt-get install -y libasound2-dev pkg-config clang cmake ninja-build libgtk-3-dev
```

## Verification

```bash
# Check everything
echo "Java: $(java --version 2>&1 | head -1)"
echo "ADB: $(adb --version | head -1)"
echo "SDK: $(sdkmanager --version 2>/dev/null)"
echo "Rust: $(rustc --version 2>/dev/null)"
echo "Flutter: $(flutter --version 2>/dev/null | head -1)"
```
