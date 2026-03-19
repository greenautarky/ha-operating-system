#!/usr/bin/env bash
# android/setup.sh — One-time Android test environment setup
#
# Fully automated: downloads and installs everything needed to run the GA app
# test suite from scratch on a fresh Linux machine.
#
#   1. Android SDK cmdline-tools  (auto-downloaded, ~130 MB)
#   2. Android SDK packages       platform-tools + emulator + system-image (~2 GB)
#   3. Android Virtual Device     ga-test (Pixel 5, Android 14 x86_64)
#   4. KVM check                  hardware acceleration (strongly recommended)
#   5. npm dependencies           WebDriverIO + Appium
#   6. Appium UiAutomator2 driver
#   7. HA Companion debug APK     via gh CLI, or manual instructions
#   8. Shell environment          adds ANDROID_HOME to ~/.bashrc / ~/.zshrc
#
# Run from the repo root (idempotent — safe to re-run):
#   tests/app/android/setup.sh
#
# Prerequisites (auto-checked with install hints):
#   - Java 17+    (sudo apt install default-jdk-headless)
#   - Node.js 20+ (already required for e2e tests)
#   - curl, unzip (sudo apt install curl unzip)
#   - ~4 GB free disk space
#
# Environment variables (all optional):
#   ANDROID_HOME   SDK install dir         (default: ~/Android/Sdk)
#   AVD_NAME       emulator AVD name       (default: ga-test)
#   SYSTEM_IMAGE   SDK system image pkg    (default: android-34 x86_64 google_apis)
#   CMDLINE_TOOLS_BUILD  build number for cmdline-tools download (default: 11076708)
#   SKIP_APK       set to 1 to skip APK download step

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"

ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
AVD_NAME="${AVD_NAME:-ga-test}"
SYSTEM_IMAGE="${SYSTEM_IMAGE:-system-images;android-34;google_apis;x86_64}"
CMDLINE_TOOLS_BUILD="${CMDLINE_TOOLS_BUILD:-11076708}"

CMDLINE_TOOLS_DIR="$ANDROID_HOME/cmdline-tools/latest"
SDKMANAGER="$CMDLINE_TOOLS_DIR/bin/sdkmanager"
AVDMANAGER="$CMDLINE_TOOLS_DIR/bin/avdmanager"

# ── Helper functions (must be defined before use) ─────────────────────────────

print_apk_instructions() {
  local dest="$1"
  echo ""
  echo "  ⚠  Could not download APK automatically."
  echo ""
  echo "  A DEBUG build of the HA Companion app is required."
  echo "  (Release APKs from Google Play do NOT expose WebView to Appium.)"
  echo ""
  echo "  Option A — GitHub Actions artifact (easiest, no build needed):"
  echo "    1. Open: https://github.com/home-assistant/android/actions"
  echo "    2. Click the latest successful 'Build' workflow run"
  echo "    3. Download the 'full-debug' artifact (zip → extract .apk)"
  echo "    4. Save as: $dest"
  echo ""
  echo "  Option B — build from source:"
  echo "    git clone https://github.com/home-assistant/android"
  echo "    cd android && ./gradlew assembleFullDebug"
  echo "    cp app/build/outputs/apk/full/debug/*.apk $dest"
  echo ""
}

step() { echo ""; echo "── $* ──"; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠  $*"; }

# ── Header ────────────────────────────────────────────────────────────────────

echo "======================================================="
echo "  GA App Test Environment Setup"
echo "  ANDROID_HOME : $ANDROID_HOME"
echo "  AVD name     : $AVD_NAME"
echo "  System image : $SYSTEM_IMAGE"
echo "======================================================="

# ── Step 1: Prerequisites ─────────────────────────────────────────────────────

step "Checking prerequisites"

check_prereq() {
  local cmd="$1" hint="$2"
  if ! command -v "$cmd" &>/dev/null; then
    echo "  ERROR: '$cmd' not found — $hint"
    exit 1
  fi
}

check_prereq java   "sudo apt install default-jdk-headless"
check_prereq curl   "sudo apt install curl"
check_prereq unzip  "sudo apt install unzip"
check_prereq node   "install Node.js 20+ from https://nodejs.org"

JAVA_VER=$(java -version 2>&1 | grep -o '"[0-9]*' | head -1 | tr -d '"')
if [[ "${JAVA_VER:-0}" -lt 17 ]]; then
  echo "  ERROR: Java 17+ required (found Java ${JAVA_VER:-?})"
  echo "         sudo apt install default-jdk-headless"
  exit 1
fi
ok "Java $JAVA_VER, Node $(node --version)"

# ── Step 2: Android SDK cmdline-tools ─────────────────────────────────────────

step "Android SDK cmdline-tools"

if [[ -d "$CMDLINE_TOOLS_DIR" ]]; then
  ok "cmdline-tools already installed ($(\"$SDKMANAGER\" --version 2>/dev/null || echo 'ok'))"
else
  echo "  Downloading Android cmdline-tools (build $CMDLINE_TOOLS_BUILD, ~130 MB)..."
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  TMPZIP=$(mktemp /tmp/cmdline-tools-XXXXXX.zip)
  curl -# -L -o "$TMPZIP" \
    "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_BUILD}_latest.zip"
  TMPDIR_EXTRACT=$(mktemp -d)
  unzip -q "$TMPZIP" -d "$TMPDIR_EXTRACT"
  # Google zips the tools as cmdline-tools/ — rename to latest/
  mv "$TMPDIR_EXTRACT/cmdline-tools" "$CMDLINE_TOOLS_DIR"
  rm -f "$TMPZIP"
  rm -rf "$TMPDIR_EXTRACT"
  ok "cmdline-tools installed ($("$SDKMANAGER" --version 2>/dev/null))"
fi

export PATH="$CMDLINE_TOOLS_DIR/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

# ── Step 3: SDK licenses ──────────────────────────────────────────────────────

step "Accepting SDK licenses"
yes | "$SDKMANAGER" --licenses > /dev/null 2>&1 || true
ok "Licenses accepted"

# ── Step 4: SDK packages ──────────────────────────────────────────────────────

step "SDK packages (platform-tools, emulator, system-image)"

PKGS_NEEDED=()
[[ ! -f "$ANDROID_HOME/platform-tools/adb"     ]] && PKGS_NEEDED+=("platform-tools")
[[ ! -f "$ANDROID_HOME/emulator/emulator"       ]] && PKGS_NEEDED+=("emulator")
[[ ! -d "$ANDROID_HOME/system-images/android-34" ]] && PKGS_NEEDED+=("$SYSTEM_IMAGE")

if [[ ${#PKGS_NEEDED[@]} -eq 0 ]]; then
  ok "All packages already installed"
else
  echo "  Installing: ${PKGS_NEEDED[*]}"
  echo "  (platform-tools + emulator: ~200 MB, system-image: ~1.5 GB)"
  "$SDKMANAGER" "${PKGS_NEEDED[@]}" 2>&1 | grep -E 'Downloading|Unzipping|Done' | grep -v '^\[' || true
  ok "SDK packages installed"
fi

# ── Step 5: KVM check (hardware acceleration) ─────────────────────────────────

step "KVM hardware acceleration"

if [[ -e /dev/kvm ]]; then
  if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    ok "KVM available and accessible (/dev/kvm) — emulator will run at full speed"
  else
    warn "/dev/kvm exists but is not accessible by this user"
    warn "Add yourself to the kvm group:  sudo usermod -aG kvm \$USER  (then re-login)"
    warn "Emulator will fall back to software rendering (much slower)"
  fi
else
  warn "/dev/kvm not found — running without hardware acceleration (slow)"
  warn "On bare metal: ensure VT-x/AMD-V is enabled in BIOS"
  warn "On a VM: enable nested virtualisation for the VM"
fi

# ── Step 6: Create AVD ────────────────────────────────────────────────────────

step "Android Virtual Device: $AVD_NAME"

AVD_DIR="$HOME/.android/avd/${AVD_NAME}.avd"
if [[ -d "$AVD_DIR" ]]; then
  ok "AVD '$AVD_NAME' already exists"
else
  echo "  Creating Pixel 5, Android 14 AVD..."
  echo "no" | "$AVDMANAGER" create avd \
    --name "$AVD_NAME" \
    --package "$SYSTEM_IMAGE" \
    --device "pixel_5" \
    --force 2>&1 | grep -vE '^(INFO|Loading|Fetch|\[)' || true
  ok "AVD '$AVD_NAME' created (Pixel 5, Android 14 x86_64)"
fi

# ── Step 7: npm dependencies + Appium ────────────────────────────────────────

step "npm dependencies + Appium"

cd "$APP_DIR"
if [[ ! -d node_modules ]]; then
  npm install --silent
  ok "npm packages installed"
else
  ok "node_modules already present (run 'npm install' to update)"
fi

echo "  Installing Appium UiAutomator2 driver..."
npx appium driver install uiautomator2 2>&1 | grep -E 'Driver|installed|already' | head -3 || true
ok "Appium + UiAutomator2 ready"

# ── Step 8: HA Companion APK ──────────────────────────────────────────────────
#
# Two APK variants:
#
#   RELEASE APK (app-full-release.apk from GitHub releases)
#     ✓ Easy to get via gh CLI
#     ✓ Good for manual testing: shows real app UI, can connect to iHost
#     ✗ NO WebView debugging → Appium cannot inspect HTML elements
#     → Saved as: ha-companion-release.apk
#
#   DEBUG APK (built from source or CI artifact)
#     ✓ Has android:debuggable=true + WebView.setWebContentsDebuggingEnabled(true)
#     ✓ Required for automated onboarding/login tests (WebView element interaction)
#     → Saved as: ha-companion.apk  (the default APK_PATH in wdio config)
#
# This step downloads the release APK automatically. For the debug APK, see the
# manual instructions printed below.

step "HA Companion APK"

APK_RELEASE="$SCRIPT_DIR/ha-companion-release.apk"
APK_DEBUG="$SCRIPT_DIR/ha-companion.apk"

if [[ "${SKIP_APK:-0}" == "1" ]]; then
  warn "Skipping APK download (SKIP_APK=1)"

else
  # ── Release APK (automatic via gh CLI) ──────────────────────────────────
  if [[ -f "$APK_RELEASE" ]]; then
    ok "Release APK already present: ha-companion-release.apk"
  elif command -v gh &>/dev/null; then
    echo "  Downloading release APK via gh CLI..."
    LATEST_TAG=$(gh release list --repo home-assistant/android --limit 1 --json tagName --jq '.[0].tagName' 2>/dev/null || echo "")
    if [[ -n "$LATEST_TAG" ]]; then
      gh release download "$LATEST_TAG" \
        --repo home-assistant/android \
        --pattern "app-full-release.apk" \
        --dir "$SCRIPT_DIR" \
        --clobber 2>/dev/null && \
      mv "$SCRIPT_DIR/app-full-release.apk" "$APK_RELEASE" 2>/dev/null || true
      [[ -f "$APK_RELEASE" ]] && ok "Release APK downloaded: ha-companion-release.apk ($LATEST_TAG)" \
                               || warn "Could not download release APK"
    fi
  else
    warn "gh CLI not found — skipping release APK download"
    warn "Install gh CLI to enable auto-download: https://cli.github.com"
  fi

  # ── Debug APK (manual — required for Appium WebView tests) ───────────────
  if [[ -f "$APK_DEBUG" ]]; then
    ok "Debug APK present: ha-companion.apk (WebView automation enabled)"
  else
    print_apk_instructions "$APK_DEBUG"
  fi
fi

# ── Step 8b: Install APK on running emulator (if available) ──────────────────

ADB="$ANDROID_HOME/platform-tools/adb"
RUNNING=$("$ADB" devices 2>/dev/null | grep -c 'emulator.*device' || true)

install_apk() {
  local apk="$1" label="$2"
  echo "  Installing $label on emulator..."
  "$ADB" -e install -r "$apk" > /dev/null 2>&1 && ok "$label installed" || warn "Install failed — start emulator first"
}

if [[ $RUNNING -gt 0 ]]; then
  [[ -f "$APK_DEBUG"   ]] && install_apk "$APK_DEBUG"   "ha-companion (debug)" \
  || [[ -f "$APK_RELEASE" ]] && install_apk "$APK_RELEASE" "ha-companion (release)"
else
  warn "No emulator running — run start-emulator.sh first, then re-run this script to install APK"
fi

# ── Step 9: Shell environment ─────────────────────────────────────────────────

step "Shell environment"

EXPORT_BLOCK="# Android SDK (added by GA app test setup)
export ANDROID_HOME=\"\$HOME/Android/Sdk\"
export PATH=\"\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/platform-tools:\$ANDROID_HOME/emulator:\$PATH\""

add_to_rc() {
  local rcfile="$1"
  if [[ -f "$rcfile" ]] && ! grep -q 'ANDROID_HOME' "$rcfile"; then
    echo "" >> "$rcfile"
    echo "$EXPORT_BLOCK" >> "$rcfile"
    ok "Added ANDROID_HOME to $rcfile"
  elif [[ -f "$rcfile" ]]; then
    ok "ANDROID_HOME already in $rcfile"
  fi
}

add_to_rc "$HOME/.bashrc"
add_to_rc "$HOME/.zshrc"
echo "  (reload shell or run: export ANDROID_HOME=\$HOME/Android/Sdk)"

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "======================================================="
echo "  Setup complete!"
echo ""
echo "  Start emulator:"
echo "    tests/app/android/start-emulator.sh"
echo ""
echo "  Run app tests (emulator must be running):"
echo "    RUN_APP_TESTS=1 DEVICE_IP=<ip> HA_ADMIN_PASS=<pass> \\"
echo "      tests/run_app_tests.sh --ssh root@<ip> --no-avd"
echo ""
if [[ ! -f "$APK_DEST" ]]; then
  echo "  ⚠  APK still needed — see instructions above."
  echo ""
fi
echo "======================================================="
