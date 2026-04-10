import { test, expect } from '../fixtures/device';

/**
 * Password Reset — E2E tests
 *
 * Tests the PIN-based password reset page at /greenautarky-password-reset.
 * Non-destructive tests (page loads, PIN input) can run anytime.
 *
 * Run:
 *   DEVICE_IP=<ip> npx playwright test tests/password-reset.spec.ts
 */

test.describe('Password Reset — Page', () => {
  test('reset page loads and shows PIN input', async ({ page, deviceUrl }) => {
    const res = await page.goto(`${deviceUrl}/greenautarky-password-reset`);
    expect(res?.status()).toBe(200);

    // Page title
    const text = (await page.textContent('body')) ?? '';
    expect(/passwort.*zurücksetzen/i.test(text)).toBe(true);

    // PIN input visible
    const pinInput = page.locator('#pin');
    await expect(pinInput).toBeVisible({ timeout: 5_000 });
  });

  test('PIN input auto-formats with dash', async ({ page, deviceUrl }) => {
    await page.goto(`${deviceUrl}/greenautarky-password-reset`);
    const pinInput = page.locator('#pin');
    await pinInput.fill('123456');

    const value = await pinInput.inputValue();
    expect(value).toBe('123-456');
  });

  test('wrong PIN shows error message', async ({ page, deviceUrl }) => {
    await page.goto(`${deviceUrl}/greenautarky-password-reset`);
    const pinInput = page.locator('#pin');
    await pinInput.fill('000000');
    await page.locator('#btn-pin').click();

    // Wait for error
    const error = page.locator('#pin-error');
    await expect(error).toBeVisible({ timeout: 10_000 });
    const errorText = (await error.textContent()) ?? '';
    expect(/ungültige pin|invalid/i.test(errorText)).toBe(true);
  });

  test('back link goes to login', async ({ page, deviceUrl }) => {
    await page.goto(`${deviceUrl}/greenautarky-password-reset`);
    const backLink = page.locator('a.btn-secondary');
    await expect(backLink).toBeVisible();
    expect(await backLink.getAttribute('href')).toBe('/');
  });

  test('no critical JS errors on page load', async ({ page, deviceUrl }) => {
    const errors: string[] = [];
    page.on('pageerror', (err) => errors.push(err.message));

    await page.goto(`${deviceUrl}/greenautarky-password-reset`);
    await page.waitForSelector('#pin', { timeout: 5_000 });

    expect(errors, `JS errors: ${errors.join(', ')}`).toHaveLength(0);
  });
});

test.describe('Password Reset — API', () => {
  test('users endpoint exists (returns 401 or 404)', async ({ deviceUrl }) => {
    const res = await fetch(`${deviceUrl}/api/greenautarky_onboarding/password_reset/users`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ pin: '000000' }),
    });
    // 401 (wrong PIN) or 404 (no PIN file) — both are valid
    expect([401, 404]).toContain(res.status);
  });

  test('reset endpoint exists (returns 400 or 401 or 404)', async ({ deviceUrl }) => {
    const res = await fetch(`${deviceUrl}/api/greenautarky_onboarding/password_reset`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ pin: '000000', username: 'test', new_password: 'test' }),
    });
    // 401 (wrong PIN), 404 (no PIN file or user not found), 400 (missing fields)
    expect([400, 401, 404]).toContain(res.status);
  });
});
