/**
 * HA Login — HA Companion App (EXPERIMENTAL)
 *
 * Tests the HA login flow as rendered inside the HA Companion Android app's WebView.
 * Verifies that valid credentials succeed and invalid credentials are rejected,
 * and that the HA dashboard loads after a successful login.
 *
 * REQUIRES:
 *   RUN_APP_TESTS=1   — opt-in guard
 *   DEVICE_IP         — iHost device IP
 *   HA_ADMIN_PASS     — HA admin password
 *   AVD_NAME          — Android emulator AVD name (default: ga-test)
 *   APK_PATH          — path to a DEBUG HA Companion APK (WebView access required)
 *
 * Test order matters within this suite — each test builds on the previous app state.
 * The suite uses noReset:false (set in wdio.android.conf.ts), so the app starts fresh.
 */

import { DEVICE_URL, DEVICE_IP } from '../fixtures/device';
import { addServer, switchToWebView, waitForHA, getWebViewUrl } from '../helpers/app';

function requiresAppTests(this: Mocha.Context): boolean {
  if (!process.env.RUN_APP_TESTS) {
    this.skip();
    return false;
  }
  if (!DEVICE_IP || DEVICE_IP === 'homeassistant.local') {
    console.log('SKIP: DEVICE_IP not set');
    this.skip();
    return false;
  }
  if (!process.env.HA_ADMIN_PASS) {
    console.log('SKIP: HA_ADMIN_PASS not set (required for login tests)');
    this.skip();
    return false;
  }
  return true;
}

describe('HA Login — HA Companion App', function () {
  this.timeout(120_000);

  before(async function () {
    if (!process.env.RUN_APP_TESTS || !process.env.HA_ADMIN_PASS) {
      this.skip();
      return;
    }
    console.log(`[login] waiting for HA at ${DEVICE_URL} ...`);
    await waitForHA(DEVICE_URL, 60_000);

    // Add the server via native UI → app opens WebView with HA auth page
    await addServer(driver, DEVICE_URL);
    await switchToWebView(driver);

    // Wait for the HA login form to appear
    const usernameField = await driver.$('#username');
    await usernameField.waitForDisplayed({ timeout: 20_000 });
    console.log('[login] login screen visible');
  });

  it('login screen renders with username and password fields', async function () {
    requiresAppTests.call(this);

    const usernameField = await driver.$('#username');
    const passwordField = await driver.$('#password');

    expect(await usernameField.isDisplayed()).toBe(true);
    expect(await passwordField.isDisplayed()).toBe(true);
  });

  it('invalid credentials show an error message', async function () {
    requiresAppTests.call(this);

    const user = process.env.HA_ADMIN_USER || 'admin';

    const usernameField = await driver.$('#username');
    await usernameField.clearValue();
    await usernameField.setValue(user);

    const passwordField = await driver.$('#password');
    await passwordField.clearValue();
    await passwordField.setValue('definitely-wrong-password-XYZ-123');

    const submitBtn = await driver.$('mwc-button[raised]');
    await submitBtn.click();

    // HA shows "Invalid username or password" on bad credentials
    await driver.waitUntil(
      async () => {
        const bodyText = (await driver.execute(() => document.body.innerText)) as string;
        return (
          bodyText.toLowerCase().includes('invalid') ||
          bodyText.toLowerCase().includes('incorrect') ||
          bodyText.toLowerCase().includes('ungültig') // German
        );
      },
      { timeout: 10_000, timeoutMsg: 'No error message shown after invalid credentials' },
    );

    // Must stay on auth page after bad credentials
    const url = await getWebViewUrl(driver);
    expect(url).toMatch(/\/auth\//);
  });

  it('valid credentials log in successfully', async function () {
    requiresAppTests.call(this);

    const user = process.env.HA_ADMIN_USER || 'admin';
    const pass = process.env.HA_ADMIN_PASS!;

    // Clear any previous values and enter correct credentials
    const usernameField = await driver.$('#username');
    await usernameField.clearValue();
    await usernameField.setValue(user);

    const passwordField = await driver.$('#password');
    await passwordField.clearValue();
    await passwordField.setValue(pass);

    const submitBtn = await driver.$('mwc-button[raised]');
    await submitBtn.click();

    // Wait for redirect away from the auth page
    await driver.waitUntil(
      async () => !(await getWebViewUrl(driver)).includes('/auth/'),
      { timeout: 25_000, timeoutMsg: 'Login did not redirect — check HA_ADMIN_PASS' },
    );

    const url = await getWebViewUrl(driver);
    console.log(`[login] post-login URL: ${url}`);

    // After login, app should land on the HA dashboard or GA onboarding
    expect(url).toMatch(/lovelace|overview|greenautarky-setup/);
  });

  it('<home-assistant> element renders on the dashboard', async function () {
    requiresAppTests.call(this);

    // Navigate to the HA dashboard explicitly
    await driver.url(`${DEVICE_URL}/lovelace`);

    // The root HA web component should mount within 30s
    await driver.waitUntil(
      async () =>
        (await driver.execute(() => !!document.querySelector('home-assistant'))) as boolean,
      { timeout: 30_000, timeoutMsg: '<home-assistant> element not found — dashboard did not render' },
    );

    const haApp = await driver.$('home-assistant');
    expect(await haApp.isExisting()).toBe(true);
  });
});
