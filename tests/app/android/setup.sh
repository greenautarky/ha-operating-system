#!/usr/bin/env bash
# android/setup.sh — One-time Android test environment setup
#
# Sets up everything needed to run the GA app test suite:
#   1. Android SDK (cmdline-tools, platform-tools, emulator, system-image)
#   2. Android Virtual Device (AVD) — Pixel 5, Android 14
#   3. npm dependencies (WebDriverIO + Appium)
#   4. Appium UiAutomator2 driver
#   5. HA Companion debug APK (via gh CLI or manual download instructions)
#
# Run from the repo root:
#   tests/app/android/setup.sh
#
# Prerequisites:
#   - Java 17+   (sudo apt install default-jdk-headless)
#   - Node.js 20+ (already required for e2e tests)
#   - curl, unzip
#   - gh CLI (optional, for APK download — https://cli.github.com)
#   ~8 GB free disk space (SDK + system image + APK)
#
# Environment variables (all optional, override defaults):
#   ANDROID_HOME  — SDK install dir (default: ~/Android/Sdk)
#   AVD_NAME      — emulator name   (default: ga-test)
#   SYSTEM_IMAGE  — SDK system image (default: android-34 x86_64 google_apis)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"

ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
AVD_NAME="${AVD_NAME:-ga-test}"
SYSTEM_IMAGE="${SYSTEM_IMAGE:-system-images;android-34;google_apis;x86_64}"

# Derived paths
CMDLINE_TOOLS_DIR="$ANDROID_HOME/cmdline-tools/latest"
SDKMANAGER="$CMDLINE_TOOLS_DIR/bin/sdkmanager"
AVDMANAGER="$CMDLINE_TOOLS_DIR/bin/avdmanager"

echo "======================================================="
echo "  GA App Test Environment Setup"
echo "  ANDROID_HOME : $ANDROID_HOME"
echo "  AVD name     : $AVD_NAME"
echo "  System image : $SYSTEM_IMAGE"
echo "======================================================="
echo ""

# ── Step 1: Prerequisites ──────────────────────────────────────────────────────

check_prereq() {
  local cmd="$1" install_hint="$2"
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' not found"
    echo "       $install_hint"
    exit 1
  fi
}

check_prereq java   "sudo apt install default-jdk-headless"
check_prereq curl   "sudo apt install curl"
check_prereq unzip  "sudo apt install unzip"
check_prereq node   "Install Node.js 20+ from https://nodejs.org"

JAVA_VER=$(java -version 2>&1 | grep -o '"[0-9]*' | head -1 | tr -d '"')
if [[ "${JAVA_VER:-0}" -lt 17 ]]; then
  echo "ERROR: Java 17+ required (found Java ${JAVA_VER:-unknown})"
  exit 1
fi
echo "✓ Java $JAVA_VER"

# ── Step 2: Android SDK command-line tools ────────────────────────────────────

if [[ ! -d "$CMDLINE_TOOLS_DIR" ]]; then
  echo ""
  echo "Android command-line tools not found at $CMDLINE_TOOLS_DIR"
  echo ""
  echo "Download from: https://developer.android.com/studio#command-tools"
  echo "  1. Download 'Command line tools only' for Linux"
  echo "  2. Create:  mkdir -p $ANDROID_HOME/cmdline-tools"
  echo "  3. Extract: unzip commandlinetools-linux-*.zip -d $ANDROID_HOME/cmdline-tools"
  echo "  4. Rename:  mv $ANDROID_HOME/cmdline-tools/cmdline-tools $ANDROID_HOME/cmdline-tools/latest"
  echo "  5. Re-run:  tests/app/android/setup.sh"
  echo ""
  echo "Or if you already have Android Studio, set:"
  echo "  export ANDROID_HOME=\$HOME/Android/Sdk"
  echo "  and re-run this script."
  exit 1
fi

echo "✓ Android cmdline-tools found"
export PATH="$CMDLINE_TOOLS_DIR/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

# ── Step 3: Accept SDK licenses ───────────────────────────────────────────────

echo ""
echo "Accepting SDK licenses..."
yes | "$SDKMANAGER" --licenses > /dev/null 2>&1 || true
echo "✓ Licenses accepted"

# ── Step 4: Install SDK packages ──────────────────────────────────────────────

echo ""
echo "Installing SDK packages (platform-tools, emulator, system-image)..."
echo "This may take several minutes on first run (~2–4 GB download)."
echo ""
"$SDKMANAGER" "platform-tools" "emulator" "$SYSTEM_IMAGE" 2>&1 \
  | grep -vE '^\[=|^Info:|^\s*$' || true
echo "✓ SDK packages installed"

# ── Step 5: Create AVD ────────────────────────────────────────────────────────

AVD_CONFIG="$HOME/.android/avd/${AVD_NAME}.avd"
if [[ -d "$AVD_CONFIG" ]]; then
  echo "✓ AVD '$AVD_NAME' already exists"
else
  echo ""
  echo "Creating AVD: $AVD_NAME (Pixel 5, Android 14)..."
  echo "no" | "$AVDMANAGER" create avd \
    --name "$AVD_NAME" \
    --package "$SYSTEM_IMAGE" \
    --device "pixel_5" \
    --force 2>&1 | grep -vE '^INFO\|^\[' || true
  echo "✓ AVD '$AVD_NAME' created"
fi

# ── Step 6: npm dependencies + Appium ────────────────────────────────────────

echo ""
echo "Installing npm dependencies..."
cd "$APP_DIR"
npm install

echo ""
echo "Installing Appium UiAutomator2 driver..."
npx appium driver install uiautomator2 2>&1 | tail -5 || true
echo "✓ Appium + UiAutomator2 ready"

# ── Step 7: HA Companion debug APK ────────────────────────────────────────────

APK_DEST="$SCRIPT_DIR/ha-companion.apk"

if [[ -f "$APK_DEST" ]]; then
  echo ""
  echo "✓ APK already present: $APK_DEST"
else
  echo ""
  echo "Fetching HA Companion debug APK..."
  echo ""

  if command -v gh &>/dev/null; then
    echo "Attempting download via gh CLI from home-assistant/android..."
    if gh release download \
        --repo home-assistant/android \
        --pattern "*full-debug*" \
        --dir "$SCRIPT_DIR" \
        --clobber 2>/dev/null; then
      # Normalise filename
      find "$SCRIPT_DIR" -name "*full-debug*.apk" ! -name "ha-companion.apk" \
        | head -1 | xargs -r -I{} mv {} "$APK_DEST"
      echo "✓ APK downloaded: $APK_DEST"
    else
      print_apk_instructions
    fi
  else
    print_apk_instructions
  fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "======================================================="
echo "  Setup complete!"
echo ""
echo "  Next steps:"
echo "    1. Start emulator:  tests/app/android/start-emulator.sh"
echo "    2. Run app tests:"
echo "       RUN_APP_TESTS=1 DEVICE_IP=<ip> HA_ADMIN_PASS=<pass> \\"
echo "         tests/run_app_tests.sh --ssh root@<ip>"
echo ""
echo "  Tip: use --no-avd if the emulator is already running."
echo "======================================================="


print_apk_instructions() {
  echo "  Could not download APK automatically."
  echo ""
  echo "  Manual steps to get a debug APK:"
  echo ""
  echo "  Option A — GitHub Actions artifact (easiest):"
  echo "    1. Go to: https://github.com/home-assistant/android/actions"
  echo "    2. Open the latest successful 'Build' workflow run"
  echo "    3. Download the 'full-debug' artifact"
  echo "    4. Extract the .apk and save as: $APK_DEST"
  echo ""
  echo "  Option B — Build from source:"
  echo "    git clone https://github.com/home-assistant/android.git"
  echo "    cd android"
  echo "    ./gradlew assembleFullDebug"
  echo "    cp app/build/outputs/apk/full/debug/*.apk $APK_DEST"
  echo ""
  echo "  NOTE: The release APK (Google Play) does NOT support WebView automation."
  echo "        A debug build is required for tests that inspect HTML elements."
  echo ""
}
