/**
 * GA Onboarding — HA Companion App (EXPERIMENTAL)
 *
 * Tests the GA onboarding wizard (/greenautarky-setup) as rendered inside
 * the HA Companion Android app's WebView.
 *
 * REQUIRES:
 *   RUN_APP_TESTS=1   — opt-in guard
 *   DEVICE_IP         — iHost device IP
 *   HA_ADMIN_PASS     — admin password (used to log in before checking onboarding)
 *   AVD_NAME          — Android emulator AVD name (default: ga-test)
 *   APK_PATH          — path to a DEBUG HA Companion APK (WebView access required)
 *
 * APK REQUIREMENT:
 *   The release APK (Google Play / GitHub releases) does NOT expose its WebView
 *   for Appium automation. You must use a debug build:
 *     - Download from home-assistant/android GitHub Actions → "full-debug" artifact
 *     - Or build locally: ./gradlew assembleFullDebug
 *   See tests/app/android/setup.sh for setup instructions.
 *
 * OPEN QUESTION (verify on first run):
 *   After stock HA onboarding (Phase 1, done by flasher) but before GA onboarding
 *   (Phase 2), the app may either:
 *     a) Show the HA login screen → user logs in → app redirects to /greenautarky-setup
 *     b) Redirect directly to /greenautarky-setup before login
 *   This suite handles case (a): login first, then verify the onboarding panel.
 */

import { DEVICE_URL, DEVICE_IP } from '../fixtures/device';
import {
  addServer,
  switchToWebView,
  waitForHA,
  getWebViewUrl,
  loginInWebView,
} from '../helpers/app';

/** Skip the test with a clear message if required env vars are not set. */
function requiresAppTests(this: Mocha.Context): boolean {
  if (!process.env.RUN_APP_TESTS) {
    this.skip(); // Mocha skip
    return false;
  }
  if (!DEVICE_IP || DEVICE_IP === 'homeassistant.local') {
    console.log('SKIP: DEVICE_IP not set');
    this.skip();
    return false;
  }
  return true;
}

describe('GA Onboarding — HA Companion App', function () {
  this.timeout(120_000);

  before(async function () {
    if (!process.env.RUN_APP_TESTS) {
      this.skip();
      return;
    }
    console.log(`[onboarding] waiting for HA at ${DEVICE_URL} ...`);
    await waitForHA(DEVICE_URL, 60_000);
  });

  it('app launches and shows the Add Server screen', async function () {
    requiresAppTests.call(this);

    // After fresh install, the welcome / add-server screen should appear
    const addBtn = await driver.$(
      'android=new UiSelector().textMatches("(?i)add.server|get.started")',
    );
    await addBtn.waitForDisplayed({ timeout: 15_000 });
    expect(await addBtn.getText()).toBeTruthy();
  });

  it('app connects to the iHost device', async function () {
    requiresAppTests.call(this);

    await addServer(driver, DEVICE_URL);

    // After connecting, app opens a WebView with the HA auth / onboarding page
    await switchToWebView(driver);
    const url = await getWebViewUrl(driver);
    console.log(`[onboarding] WebView URL after connect: ${url}`);

    // URL must be on the iHost — either auth page or HA frontend
    expect(url).toContain(DEVICE_IP);
  });

  it('GA onboarding panel is accessible in the WebView', async function () {
    requiresAppTests.call(this);

    const url = await getWebViewUrl(driver);

    // If the app landed on the HA login screen, log in first
    if (url.includes('/auth/') || url.includes('authorize')) {
      console.log('[onboarding] login page detected — authenticating before checking onboarding');
      await loginInWebView(driver);
    }

    // Navigate to the GA onboarding panel
    await driver.url(`${DEVICE_URL}/greenautarky-setup`);
    await driver.waitUntil(
      async () => (await getWebViewUrl(driver)).includes('greenautarky-setup'),
      { timeout: 15_000, timeoutMsg: '/greenautarky-setup did not load' },
    );

    const finalUrl = await getWebViewUrl(driver);
    expect(finalUrl).toContain('greenautarky-setup');
  });

  it('<ha-panel-greenautarky-setup> web component is attached', async function () {
    requiresAppTests.call(this);

    const attached = await driver.execute(
      () => !!document.querySelector('ha-panel-greenautarky-setup'),
    );
    expect(attached).toBe(true);
  });

  it('GDPR step renders with an unchecked consent checkbox', async function () {
    requiresAppTests.call(this);

    // Wait for the GDPR step component to render
    await driver.waitUntil(
      async () =>
        (await driver.execute(() => !!document.querySelector('ga-setup-gdpr'))) as boolean,
      { timeout: 20_000, timeoutMsg: 'ga-setup-gdpr not found in DOM' },
    );

    // The consent checkbox must exist and start unchecked
    const checkbox = await driver.$('ga-setup-gdpr input[type="checkbox"]');
    expect(await checkbox.isSelected()).toBe(false);
  });

  it('GDPR: checking the consent checkbox enables the Continue button', async function () {
    requiresAppTests.call(this);

    const checkbox = await driver.$('ga-setup-gdpr input[type="checkbox"]');
    await checkbox.click();

    // Continue / Weiter button should become enabled after consent
    await driver.waitUntil(
      async () => {
        // Try English then German button text
        for (const label of ['Continue', 'Weiter']) {
          try {
            const btn = await driver.$(`mwc-button=${label}`);
            const disabled = await btn.getAttribute('disabled');
            if (disabled === null) return true;
          } catch {
            // Label not found, try next
          }
        }
        return false;
      },
      {
        timeout: 5_000,
        timeoutMsg: 'Continue button did not become enabled after GDPR consent',
      },
    );
  });
});
