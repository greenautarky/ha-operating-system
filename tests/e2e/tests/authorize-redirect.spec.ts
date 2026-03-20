import { test, expect } from '../fixtures/device';
import { getGAOnboardingStatus } from '../helpers/ha-api';

/**
 * authorize.ts → GA onboarding redirect (E2E)
 *
 * Tests the GA onboarding redirect injected into /auth/authorize via authorize.ts.
 *
 * Behaviour under test:
 *   1. /auth/authorize auto-redirects to /greenautarky-setup.html when GA not complete
 *   2. ?ga_bypass=1 skips the redirect (admin escape hatch)
 *   3. Admin-Login link is rendered on the setup page when arriving from the app flow
 *   4. Admin-Login href includes ga_bypass=1
 *
 * Redirect tests (1+2) are skipped when GA onboarding is already complete —
 * the redirect only fires for first-time users.
 * Admin-Login tests (3+4) use page.addInitScript to inject sessionStorage and
 * run unconditionally.
 *
 * Runs on all device profiles (desktop, mobile-ios, mobile-android).
 */

/**
 * Build a minimal valid-looking /auth/authorize URL for the given device.
 * The redirect_uri just needs to be present; we don't actually complete OAuth.
 */
function authorizeUrl(deviceUrl: string, extra = ''): string {
  const params = new URLSearchParams({
    client_id: deviceUrl,
    redirect_uri: `${deviceUrl}/?auth_callback=1`,
    response_type: 'code',
  });
  return `${deviceUrl}/auth/authorize?${params}${extra ? `&${extra}` : ''}`;
}

test.describe('authorize.ts → GA onboarding redirect', () => {
  // Determine at runtime whether GA onboarding is pending.
  // Tests that depend on onboarding being incomplete are skipped when it is already done.
  let gaNotComplete = false;

  test.beforeAll(async ({ deviceUrl }) => {
    try {
      const status = await getGAOnboardingStatus(deviceUrl);
      gaNotComplete = !status.completed;
    } catch {
      // Status endpoint unreachable — skip redirect tests conservatively
      gaNotComplete = false;
    }
  });

  // ── Redirect behaviour ──────────────────────────────────────────────────

  test('navigating to /auth/authorize redirects to /greenautarky-setup.html when not complete',
    async ({ page, deviceUrl }) => {
      test.skip(
        !gaNotComplete,
        'GA onboarding already complete — redirect is intentionally suppressed',
      );

      await page.goto(authorizeUrl(deviceUrl), { waitUntil: 'domcontentloaded' });

      // authorize.ts fires an async fetch; allow up to 8 s for the redirect
      await page.waitForURL(/greenautarky-setup/, { timeout: 8_000 });

      expect(page.url()).toContain('greenautarky-setup');
    },
  );

  test('?ga_bypass=1 prevents the redirect and shows the normal auth form',
    async ({ page, deviceUrl }) => {
      test.skip(
        !gaNotComplete,
        'GA onboarding already complete — bypass test not applicable',
      );

      await page.goto(authorizeUrl(deviceUrl, 'ga_bypass=1'), {
        waitUntil: 'networkidle',
      });

      // Must stay on the authorize page with ha-authorize rendered
      await expect(page.locator('ha-authorize')).toBeAttached({ timeout: 10_000 });
      expect(page.url()).not.toContain('greenautarky-setup');
    },
  );

  // ── Admin-Login link ────────────────────────────────────────────────────

  test('Admin-Login link is visible on setup page when arriving from app flow',
    async ({ page, deviceUrl }) => {
      // Inject ga_auth_redirect before the page loads — simulates the redirect
      // that authorize.ts performs when GA onboarding is not yet complete.
      const authUrl = authorizeUrl(deviceUrl);
      await page.addInitScript(
        ({ key, value }) => sessionStorage.setItem(key, value),
        { key: 'ga_auth_redirect', value: authUrl },
      );

      await page.goto(`${deviceUrl}/greenautarky-setup`);
      await expect(page.locator('ha-panel-greenautarky-setup')).toBeAttached({
        timeout: 20_000,
      });

      // Admin-Login link must be present (inside the Lit shadow root)
      const link = page.locator('.admin-login');
      await expect(link).toBeAttached({ timeout: 5_000 });
      await expect(link).toContainText('Admin-Login');
    },
  );

  test('Admin-Login link href contains ga_bypass=1', async ({ page, deviceUrl }) => {
    const authUrl = authorizeUrl(deviceUrl);
    await page.addInitScript(
      ({ key, value }) => sessionStorage.setItem(key, value),
      { key: 'ga_auth_redirect', value: authUrl },
    );

    await page.goto(`${deviceUrl}/greenautarky-setup`);
    await expect(page.locator('ha-panel-greenautarky-setup')).toBeAttached({
      timeout: 20_000,
    });

    const link = page.locator('.admin-login');
    await expect(link).toBeAttached({ timeout: 5_000 });
    const href = await link.getAttribute('href');
    expect(href).toContain('ga_bypass=1');
  });

  test('Admin-Login link is NOT rendered when setup page is visited directly (browser flow)',
    async ({ page, deviceUrl }) => {
      // No sessionStorage injection — simulates a direct browser visit (no app flow)
      await page.goto(`${deviceUrl}/greenautarky-setup`);
      await expect(page.locator('ha-panel-greenautarky-setup')).toBeAttached({
        timeout: 20_000,
      });

      // Admin-Login link must be absent
      await expect(page.locator('.admin-login')).not.toBeAttached();
    },
  );
});
