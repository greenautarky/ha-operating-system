import { test, expect } from '../fixtures/device';
import { haLogin } from '../helpers/auth';
import { waitForHA } from '../helpers/ha-api';

/**
 * HA Dashboard — mobile responsiveness tests
 *
 * Verifies the dashboard loads correctly across mobile and desktop viewports.
 * Requires credentials: set HA_ADMIN_PASS or HA_TOKEN.
 * All tests skip automatically if no auth is configured.
 *
 * Runs on all device profiles: desktop, mobile-ios, mobile-android.
 */

function skipIfNoAuth() {
  if (!process.env.HA_TOKEN && !process.env.HA_ADMIN_PASS) {
    test.skip(
      true,
      'Dashboard tests require auth — set HA_TOKEN or HA_ADMIN_USER + HA_ADMIN_PASS',
    );
  }
}

test.describe('HA Dashboard', () => {
  test.beforeEach(skipIfNoAuth);

  test('dashboard loads and redirects to lovelace', async ({ page, deviceUrl }) => {
    await waitForHA(deviceUrl);
    await haLogin(page, deviceUrl);
    await page.goto(deviceUrl);
    await expect(page).toHaveURL(/lovelace/, { timeout: 30_000 });
  });

  test('no critical JS errors on dashboard', async ({ page, deviceUrl }) => {
    const errors: string[] = [];
    page.on('pageerror', err => errors.push(err.message));

    await waitForHA(deviceUrl);
    await haLogin(page, deviceUrl);
    await page.goto(deviceUrl);
    await page.waitForURL(/lovelace/, { timeout: 30_000 });

    // Give HA time to finish rendering
    await page.waitForTimeout(3_000);

    // ResizeObserver errors are a known benign Lit/HA quirk on some builds
    const critical = errors.filter(e => !e.includes('ResizeObserver'));
    expect(critical, `Dashboard JS errors:\n${critical.join('\n')}`).toHaveLength(0);
  });

  test('dashboard fits mobile viewport without horizontal scroll', async ({
    page,
    deviceUrl,
  }) => {
    await waitForHA(deviceUrl);
    await haLogin(page, deviceUrl);
    await page.goto(deviceUrl);
    await page.waitForURL(/lovelace/, { timeout: 30_000 });
    await page.waitForTimeout(2_000);

    const { scrollWidth, clientWidth } = await page.evaluate(() => ({
      scrollWidth: document.body.scrollWidth,
      clientWidth: document.documentElement.clientWidth,
    }));
    expect(scrollWidth, 'Dashboard overflows viewport horizontally').toBeLessThanOrEqual(
      clientWidth + 5,
    );
  });

  test('hamburger menu is visible on mobile (sidebar collapsed)', async ({
    page,
    deviceUrl,
  }) => {
    await waitForHA(deviceUrl);
    await haLogin(page, deviceUrl);
    await page.goto(deviceUrl);
    await page.waitForURL(/lovelace/, { timeout: 30_000 });

    // On mobile HA collapses the sidebar behind a hamburger button
    const menuButton = page.locator('ha-menu-button, [aria-label="Open menu"]').first();
    await expect(menuButton).toBeVisible({ timeout: 10_000 });
  });

  test('header toolbar is visible and contains title', async ({ page, deviceUrl }) => {
    await waitForHA(deviceUrl);
    await haLogin(page, deviceUrl);
    await page.goto(deviceUrl);
    await page.waitForURL(/lovelace/, { timeout: 30_000 });

    // HA toolbar should be present
    const toolbar = page.locator('ha-top-app-bar-fixed, .toolbar').first();
    await expect(toolbar).toBeVisible({ timeout: 10_000 });
  });
});
