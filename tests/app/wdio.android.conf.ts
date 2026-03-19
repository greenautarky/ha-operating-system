import type { Options } from '@wdio/types';
import path from 'path';
import fs from 'fs';

/**
 * WebDriverIO + Appium configuration for GA Android app tests.
 *
 * Targets the HA Companion app running in an Android emulator.
 * Tests interact with both the native Android UI (server setup) and the
 * app's WebView (HA pages — onboarding, login, dashboard).
 *
 * IMPORTANT — WebView automation requirement:
 *   WebView interaction (HTML element inspection, URL reading) requires a
 *   debug/debuggable APK with android:debuggable=true and WebView debugging
 *   enabled (WebView.setWebContentsDebuggingEnabled(true)).
 *
 *   The official release APK from Google Play / GitHub does NOT expose WebView
 *   for automation. Use:
 *     a) A debug build from CI: home-assistant/android GitHub Actions artifacts
 *     b) Build from source with `./gradlew assembleDebug`
 *
 * Setup (run once):
 *   tests/app/android/setup.sh
 *
 * Run:
 *   RUN_APP_TESTS=1 DEVICE_IP=<ip> HA_ADMIN_PASS=<pass> tests/run_app_tests.sh --ssh root@<ip>
 */

const DEVICE_IP = process.env.DEVICE_IP || 'homeassistant.local';
export const APP_URL = process.env.DEVICE_URL || `http://${DEVICE_IP}:8123`;

const AVD_NAME = process.env.AVD_NAME || 'ga-test';
const APK_PATH =
  process.env.APK_PATH || path.join(__dirname, 'android', 'ha-companion.apk');

// Fail fast if APK is missing — better error than a confusing Appium failure
if (!fs.existsSync(APK_PATH)) {
  console.error(`\nERROR: HA Companion APK not found at:\n  ${APK_PATH}\n`);
  console.error('Run setup to download:');
  console.error('  tests/app/android/setup.sh\n');
  console.error('Or point to an existing APK:');
  console.error('  APK_PATH=/path/to/ha-companion-debug.apk tests/run_app_tests.sh ...\n');
  process.exit(1);
}

export const config: Options.Testrunner = {
  runner: 'local',

  autoCompileOpts: {
    autoCompile: true,
    tsNodeOpts: {
      project: path.join(__dirname, 'tsconfig.json'),
      transpileOnly: true,
    },
  },

  specs: ['./tests/**/*.spec.ts'],

  // Single device — run tests sequentially to avoid race conditions
  maxInstances: 1,

  capabilities: [
    {
      platformName: 'Android',

      // Emulator AVD to use (must exist — created by android/setup.sh)
      'appium:deviceName': AVD_NAME,
      'appium:avd': AVD_NAME,

      // Fresh install each test suite run
      'appium:app': APK_PATH,
      'appium:noReset': false,

      'appium:automationName': 'UiAutomator2',

      // Grant permissions automatically (location, notifications, etc.)
      'appium:autoGrantPermissions': true,

      // Timeouts
      'appium:newCommandTimeout': 120,
      'appium:androidInstallTimeout': 90_000,
      'appium:adbExecTimeout': 30_000,

      // UiAutomator2 will auto-download matching ChromeDriver for WebView access.
      // Requires relaxedSecurity on the Appium server (set below in services).
      'appium:chromedriverAutodownload': true,
    },
  ],

  logLevel: 'warn',
  bail: 0,

  waitforTimeout: 30_000,
  connectionRetryTimeout: 180_000,
  connectionRetryCount: 3,

  services: [
    [
      'appium',
      {
        // Use the locally installed appium (in node_modules/.bin after npm install)
        command: 'node_modules/.bin/appium',
        logPath: './',
        args: {
          // Allows ChromeDriver auto-download for WebView context switching
          relaxedSecurity: true,
        },
      },
    ],
  ],

  framework: 'mocha',
  reporters: ['spec'],

  mochaOpts: {
    ui: 'bdd',
    timeout: 120_000,
  },
};
