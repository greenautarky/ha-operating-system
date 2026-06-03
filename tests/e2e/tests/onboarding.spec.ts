import { test, expect } from '../fixtures/device';
import { waitForHA } from '../helpers/ha-api';

/**
 * GA Full Onboarding Flow — interactive wizard tests (DESTRUCTIVE)
 *
 * Tests the complete multi-step GA wizard:
 *   Welcome → GDPR → User creation → Info pages → Analytics → redirect to login
 *
 * REQUIRES:
 *   RESET_ONBOARDING=1   — opt-in guard (prevents accidental runs)
 *   DEVICE_IP            — SSH access for state reset
 *
 * Each test resets the GA onboarding state on the device and restarts HA Core
 * (~15-20s downtime per test). Only run on dedicated test devices.
 *
 * Run:
 *   DEVICE_IP=192.168.1.100 RESET_ONBOARDING=1 npx playwright test tests/onboarding.spec.ts
 */

function requiresReset() {
  if (!process.env.RESET_ONBOARDING) {
    test.skip(true, 'Set RESET_ONBOARDING=1 to enable destructive onboarding tests');
  }
  if (!process.env.DEVICE_IP) {
    test.skip(true, 'DEVICE_IP required — SSH is used to reset onboarding state');
  }
}

/**
 * Click through the initial Welcome page ("greenautarky KI-Butler" →
 * "Mein KI-Butler einrichten" button) which precedes the GDPR step.
 * Idempotent: returns immediately if the welcome panel isn't shown
 * (e.g. wizard rendered straight into GDPR for some future variant).
 *
 * Implementation note: the wizard panel mounts almost immediately but
 * the welcome content streams in over ~1-2s. Race condition between
 * "panel attached" and "welcome button rendered" was making a shorter
 * wait return false before the button appeared. Use getByRole which
 * pierces shadow DOM and matches the accessible name.
 */
async function dismissWelcomePage(page: import('@playwright/test').Page) {
  const welcomeBtn = page.getByRole('button', { name: /einrichten|start|begin/i }).first();
  // Race the welcome button against the GDPR step rendering directly. Either
  // resolves and we move on; if neither shows up in 15s we fail explicitly.
  const gdpr = page.locator('ga-setup-gdpr').first();
  const winner = await Promise.race([
    welcomeBtn.waitFor({ state: 'visible', timeout: 15_000 }).then(() => 'welcome' as const),
    gdpr.waitFor({ state: 'visible', timeout: 15_000 }).then(() => 'gdpr' as const),
  ]);
  if (winner === 'welcome') {
    await welcomeBtn.click();
  }
}

test.describe('GA Onboarding — wizard', () => {
  test.beforeEach(async ({ resetOnboarding }) => {
    requiresReset();
    // Reset GA onboarding state and restart HA Core
    resetOnboarding();
    // HA Core takes ~15-20s to come back up after restart
    await new Promise(r => setTimeout(r, 20_000));
  });

  test('wizard is accessible at /greenautarky-setup after reset', async ({
    page,
    deviceUrl,
  }) => {
    await waitForHA(deviceUrl, 60_000);
    const res = await page.goto(`${deviceUrl}/greenautarky-setup`);
    expect(res?.status()).not.toBe(404);
    await expect(page.locator('ha-panel-greenautarky-setup')).toBeAttached({ timeout: 20_000 });
  });

  test('GDPR step renders with unchecked consent checkbox', async ({ page, deviceUrl }) => {
    await waitForHA(deviceUrl, 60_000);
    await page.goto(`${deviceUrl}/greenautarky-setup`);
    await page.waitForSelector('ha-panel-greenautarky-setup', { timeout: 20_000 });
    await dismissWelcomePage(page);

    // ga-setup-gdpr.ts renders a checkbox for Datenschutz/GDPR consent
    const checkbox = page.locator('ga-setup-gdpr input[type="checkbox"]').first();
    await expect(checkbox).toBeVisible({ timeout: 15_000 });
    expect(await checkbox.isChecked()).toBe(false);
  });

  test('GDPR: accepting consent enables the continue button', async ({ page, deviceUrl }) => {
    await waitForHA(deviceUrl, 60_000);
    await page.goto(`${deviceUrl}/greenautarky-setup`);
    await page.waitForSelector('ha-panel-greenautarky-setup', { timeout: 20_000 });
    await dismissWelcomePage(page);
    await page.waitForSelector('ga-setup-gdpr', { timeout: 20_000 });

    const checkbox = page.locator('ga-setup-gdpr input[type="checkbox"]').first();
    await checkbox.check();

    const continueBtn = page
      .locator('button, mwc-button')
      .filter({ hasText: /continue|weiter/i })
      .first();
    await expect(continueBtn).toBeEnabled({ timeout: 5_000 });
  });

  test('user creation step is reachable after GDPR', async ({ page, deviceUrl }) => {
    await waitForHA(deviceUrl, 60_000);
    await page.goto(`${deviceUrl}/greenautarky-setup`);
    await page.waitForSelector('ha-panel-greenautarky-setup', { timeout: 20_000 });
    await dismissWelcomePage(page);
    await page.waitForSelector('ga-setup-gdpr', { timeout: 20_000 });

    // Accept GDPR and advance
    await page.locator('ga-setup-gdpr input[type="checkbox"]').first().check();
    await page
      .locator('button, mwc-button')
      .filter({ hasText: /continue|weiter/i })
      .first()
      .click();

    // User creation step should follow (ga-setup-create-user.ts)
    await expect(page.locator('ga-setup-create-user')).toBeVisible({ timeout: 15_000 });
  });

  test('user creation: password field validates strength', async ({ page, deviceUrl }) => {
    await waitForHA(deviceUrl, 60_000);
    await page.goto(`${deviceUrl}/greenautarky-setup`);

    await page.waitForSelector('ha-panel-greenautarky-setup', { timeout: 20_000 });
    await dismissWelcomePage(page);
    // Navigate to user creation step
    await page.waitForSelector('ga-setup-gdpr', { timeout: 20_000 });
    await page.locator('ga-setup-gdpr input[type="checkbox"]').first().check();
    await page
      .locator('button, mwc-button')
      .filter({ hasText: /continue|weiter/i })
      .first()
      .click();
    await page.waitForSelector('ga-setup-create-user', { timeout: 15_000 });

    // Weak password should keep submit disabled
    const passwordInput = page
      .locator('ga-setup-create-user input[type="password"]')
      .first();
    await passwordInput.fill('abc');

    const submitBtn = page
      .locator('button, mwc-button')
      .filter({ hasText: /continue|create|weiter/i })
      .first();
    await expect(submitBtn).toBeDisabled({ timeout: 3_000 });

    // Strong password should enable submit
    await passwordInput.fill('SecurePassword123!');
    await page
      .locator('ga-setup-create-user input[name="name"], ga-setup-create-user [name="name"]')
      .first()
      .fill('Test User');
    await expect(submitBtn).toBeEnabled({ timeout: 5_000 });
  });
});
