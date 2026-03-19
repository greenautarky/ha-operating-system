import { test, expect } from '../fixtures/device';
import { getGAOnboardingStatus } from '../helpers/ha-api';

/**
 * GA Setup Panel — smoke tests (read-only, no auth required)
 *
 * Tests the greenautarky_onboarding integration and the /greenautarky-setup panel.
 * These are safe to run on any device at any time — they do not modify state.
 *
 * Runs on all device profiles: desktop, mobile-ios, mobile-android.
 */

test.describe('GA Setup — API', () => {
  test('status endpoint is reachable and returns valid JSON', async ({ deviceUrl }) => {
    const status = await getGAOnboardingStatus(deviceUrl);
    expect(status).toHaveProperty('completed');
    expect(status).toHaveProperty('steps_done');
    expect(typeof status.completed).toBe('boolean');
    expect(Array.isArray(status.steps_done)).toBe(true);
  });

  test('status endpoint fields have correct types', async ({ deviceUrl }) => {
    const status = await getGAOnboardingStatus(deviceUrl);
    expect(typeof status.gdpr_accepted).toBe('boolean');
  });
});

test.describe('GA Setup — Panel', () => {
  test('panel URL loads (not 404)', async ({ page, deviceUrl }) => {
    const res = await page.goto(`${deviceUrl}/greenautarky-setup`, {
      waitUntil: 'domcontentloaded',
    });
    expect(res?.status()).not.toBe(404);
  });

  test('main web component is attached to DOM', async ({ page, deviceUrl }) => {
    await page.goto(`${deviceUrl}/greenautarky-setup`);
    // ha-panel-greenautarky-setup is the top-level Lit orchestrator (ha-panel-greenautarky-setup.ts)
    await expect(page.locator('ha-panel-greenautarky-setup')).toBeAttached({ timeout: 20_000 });
  });

  test('welcome step shows GA/HA branding content', async ({ page, deviceUrl }) => {
    await page.goto(`${deviceUrl}/greenautarky-setup`);
    await page.waitForSelector('ha-panel-greenautarky-setup', { timeout: 20_000 });

    // ga-setup-welcome.ts renders GA and HA logos/text — first step is always welcome
    const text = (await page.textContent('body')) ?? '';
    const hasExpectedContent = /greenautarky|home assistant|willkommen|welcome/i.test(text);
    expect(hasExpectedContent, 'Expected welcome step to show GA or HA branding').toBe(true);
  });

  test('no critical JS console errors on panel load', async ({ page, deviceUrl }) => {
    const errors: string[] = [];
    page.on('console', msg => {
      if (msg.type() === 'error') errors.push(msg.text());
    });
    page.on('pageerror', err => errors.push(err.message));

    await page.goto(`${deviceUrl}/greenautarky-setup`);
    await page.waitForSelector('ha-panel-greenautarky-setup', { timeout: 20_000 });

    // Filter known benign browser noise
    const critical = errors.filter(
      e =>
        !e.includes('favicon') &&
        !e.includes('net::ERR_') &&
        !e.includes('Failed to load resource'),
    );
    expect(critical, `Critical JS errors:\n${critical.join('\n')}`).toHaveLength(0);
  });

  test('panel fits mobile viewport without horizontal scroll', async ({ page, deviceUrl }) => {
    await page.goto(`${deviceUrl}/greenautarky-setup`);
    await page.waitForSelector('ha-panel-greenautarky-setup', { timeout: 20_000 });

    const { scrollWidth, clientWidth } = await page.evaluate(() => ({
      scrollWidth: document.body.scrollWidth,
      clientWidth: document.documentElement.clientWidth,
    }));
    // Allow 5px tolerance for scrollbar width differences
    expect(scrollWidth, 'Panel overflows viewport horizontally').toBeLessThanOrEqual(
      clientWidth + 5,
    );
  });
});
