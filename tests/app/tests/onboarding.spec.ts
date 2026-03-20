/**
 * GA Onboarding — HA Companion App (EXPERIMENTAL)
 *
 * Tests the GA onboarding wizard (/greenautarky-setup) as rendered inside
 * the HA Companion Android app's WebView.
 *
 * REQUIRES:
 *   RUN_APP_TESTS=1   — opt-in guard
 *   DEVICE_IP         — iHost device IP
 *   HA_ADMIN_PASS     — admin password (fallback for Admin-Login bypass test)
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
 * FLOW (confirmed behaviour):
 *   The HA Companion app navigates to /auth/authorize after connecting to the device.
 *   authorize.ts contains a GA pre-check: if GA onboarding is not yet complete,
 *   it stores the auth URL in sessionStorage and redirects to /greenautarky-setup.html.
 *   After the user completes onboarding, the panel redirects back to the stored auth URL
 *   so the app can finish its OAuth handshake.
 *   An "Admin-Login" link in the bottom-right corner bypasses the wizard (?ga_bypass=1).
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
      'android=new UiSelector().textMatches("(?i).*(add.server|get.started|connect.to.my).*")',
    );
    await addBtn.waitForDisplayed({ timeout: 15_000 });
    expect(await addBtn.getText()).toBeTruthy();
  });

  it('app connects to the iHost device', async function () {
    requiresAppTests.call(this);

    await addServer(driver, DEVICE_URL);

    // The app opens a WebView and navigates to /auth/authorize.
    // authorize.ts fires a GA pre-check: if onboarding is not complete it redirects
    // to /greenautarky-setup.html.  Wait up to 20 s for the WebView to appear.
    await switchToWebView(driver);
    const url = await getWebViewUrl(driver);
    console.log(`[onboarding] WebView URL after connect: ${url}`);

    // URL must be on the iHost device
    expect(url).toContain(DEVICE_IP);
  });

  it('/auth/authorize auto-redirects to GA onboarding (app-flow redirect)', async function () {
    requiresAppTests.call(this);

    // Poll the current WebView URL — the authorize.ts pre-check runs asynchronously
    // after the JS module loads, so the redirect may take a moment.
    await driver.waitUntil(
      async () => {
        const url = await getWebViewUrl(driver);
        return url.includes('greenautarky-setup');
      },
      {
        timeout: 15_000,
        timeoutMsg:
          'Expected /auth/authorize to redirect to /greenautarky-setup.html — ' +
          'check that authorize.ts contains the GA pre-check and GA onboarding is not yet complete',
      },
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

  it('Admin-Login link is visible in the bottom-right corner', async function () {
    requiresAppTests.call(this);

    // The Admin-Login link is rendered by the panel when ga_auth_redirect is in
    // sessionStorage (which authorize.ts sets before the redirect).
    const hasLink = await driver.execute(
      () =>
        !!document
          .querySelector('ha-panel-greenautarky-setup')
          ?.shadowRoot?.querySelector('.admin-login'),
    );
    expect(hasLink).toBe(true);
  });

  it('Admin-Login link href contains ga_bypass=1', async function () {
    requiresAppTests.call(this);

    const href = await driver.execute(
      () =>
        document
          .querySelector('ha-panel-greenautarky-setup')
          ?.shadowRoot?.querySelector('.admin-login')
          ?.getAttribute('href') ?? '',
    );
    expect(href).toContain('ga_bypass=1');
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

  it('Admin-Login bypass: ?ga_bypass=1 shows the normal HA login form', async function () {
    requiresAppTests.call(this);

    if (!process.env.HA_ADMIN_PASS) {
      this.skip();
      return;
    }

    // Construct the bypass URL — same as what the Admin-Login link points to
    const adminLoginHref: string = await driver.execute(
      () =>
        (
          document
            .querySelector('ha-panel-greenautarky-setup')
            ?.shadowRoot?.querySelector('.admin-login') as HTMLAnchorElement | null
        )?.href ?? '',
    );

    if (!adminLoginHref) {
      this.skip();
      return;
    }

    // Navigate to the bypass URL in the WebView
    await driver.url(adminLoginHref);

    // ha-authorize must render — we must NOT be redirected back to setup
    await driver.waitUntil(
      async () => {
        const url = await getWebViewUrl(driver);
        return url.includes('authorize') && !url.includes('greenautarky-setup');
      },
      {
        timeout: 10_000,
        timeoutMsg: 'ga_bypass=1 did not prevent the GA onboarding redirect',
      },
    );

    // Log in with admin credentials to confirm the auth form is functional
    await loginInWebView(driver);

    const dashUrl = await getWebViewUrl(driver);
    expect(dashUrl).not.toContain('/auth/');
  });
});
