import { test, expect } from '../fixtures/device';
import { waitForHA } from '../helpers/ha-api';

/**
 * Onboarding v1.0.5 — front-facing surfaces (greenautarky-setup + first-party cards)
 *
 * Three read-only-by-default describes:
 *   1. Siezen copy spot-checks on the wizard welcome step (no auth, no reset).
 *   2. Sub-user join wizard up to the create-user form — tolerant of the
 *      consent checkbox that is being ADDED in parallel (both variants pass).
 *      Does NOT submit → never creates a user (read-only on the device).
 *   3. ga-master-card (ADR-0006) presence: the shipped resource + custom-element
 *      registration. The stronger "renders under a master flag" assertion needs
 *      HA auth and self-skips when no token is available.
 *
 * REQUIRES: DEVICE_IP (the canary iHost).
 * OPTIONAL: HA_TOKEN | HA_ADMIN_PASS — only for the authenticated master-card
 *           render assertion; everything else is unauthenticated.
 *
 * Run:
 *   DEVICE_IP=100.126.91.112 npx playwright test tests/onboarding-v105.spec.ts --project=desktop
 */

function requireDevice() {
  if (!process.env.DEVICE_IP && !process.env.DEVICE_URL)
    test.skip(true, 'DEVICE_IP required');
}

/** Deep (shadow-piercing) text of the wizard panel — the wizard renders inside
 *  nested open shadow roots, so element.textContent alone misses it. Playwright
 *  text locators pierce shadow DOM, but for whole-panel scans we walk manually. */
async function panelDeepText(page: import('@playwright/test').Page): Promise<string> {
  return page.evaluate(() => {
    const panel = document.querySelector('ha-panel-greenautarky-setup');
    if (!panel) return '';
    const acc: string[] = [];
    const walk = (root: ParentNode) => {
      root.querySelectorAll('*').forEach((el) => {
        const sr = (el as HTMLElement & { shadowRoot?: ShadowRoot }).shadowRoot;
        if (sr) walk(sr);
      });
      acc.push((root as HTMLElement).textContent ?? '');
    };
    const sr = (panel as HTMLElement & { shadowRoot?: ShadowRoot }).shadowRoot;
    if (sr) walk(sr);
    return acc.join(' ').replace(/\s+/g, ' ');
  });
}

test.describe('Onboarding wizard — Siezen copy (read-only)', () => {
  test('welcome step uses formal Sie-address copy', async ({ page, deviceUrl }) => {
    requireDevice();
    await waitForHA(deviceUrl, 60_000);

    // The wizard only renders the welcome step when GA onboarding is not yet
    // completed. Gate on the status endpoint (deterministic) — ga-setup-welcome
    // is a box-less custom element so an isVisible() gate would false-skip.
    const status = await fetch(`${deviceUrl}/api/greenautarky_onboarding/status`)
      .then((r) => r.json())
      .catch(() => ({}));
    if (status.completed === true)
      test.skip(true, 'GA onboarding completed — welcome step not rendered; copy check needs an active wizard');

    await page.goto(`${deviceUrl}/greenautarky-setup`);
    await expect(page.locator('ha-panel-greenautarky-setup')).toBeAttached({ timeout: 20_000 });
    await expect(page.locator('ga-setup-welcome')).toBeAttached({ timeout: 15_000 });

    // getByText pierces open shadow DOM — assert the exact Siezen headline + subtitle.
    await expect(
      page.getByText('Lassen Sie uns Ihr Smart Home einrichten', { exact: false }),
    ).toBeVisible({ timeout: 10_000 });
    await expect(
      page.getByText('Willkommen bei Ihrem KI-Butler', { exact: false }),
    ).toBeVisible();

    // Negative Siezen guard: the welcome copy must not slip into informal address.
    const text = await panelDeepText(page);
    expect(text).toContain('Lassen Sie uns Ihr Smart Home einrichten');
    expect(/\bLass uns\b|\bDein Smart Home\b|\bDeinen KI-Butler\b/.test(text), 'no informal Du-address').toBe(false);
  });
});

test.describe('Sub-user join wizard — up to create-user form (read-only, no submit)', () => {
  test('join link redirects into the wizard PIN step (Einladungs-PIN)', async ({ page, deviceUrl }) => {
    requireDevice();
    await waitForHA(deviceUrl, 60_000);

    // /greenautarky-join must 302 → /greenautarky-setup.html?join=1
    const probe = await fetch(`${deviceUrl}/greenautarky-join`, { redirect: 'manual' }).catch(() => null);
    if (!probe || (probe.status !== 302 && probe.status !== 200))
      test.skip(true, 'component not patched — /greenautarky-join did not redirect');

    await page.goto(`${deviceUrl}/greenautarky-join`);
    await expect(page).toHaveURL(/greenautarky-setup\.html\?join=1/);
    await expect(page.locator('ga-setup-pin')).toBeAttached({ timeout: 20_000 });
    await expect(page.locator('ga-setup-pin')).toContainText('Einladungs-PIN', { timeout: 10_000 });
  });

  test('PIN advances to create-user step; consent checkbox tolerated (present or expected-next)', async ({
    page,
    deviceUrl,
  }, testInfo) => {
    requireDevice();
    const probe = await fetch(`${deviceUrl}/greenautarky-join`, { redirect: 'manual' }).catch(() => null);
    if (!probe || (probe.status !== 302 && probe.status !== 200))
      test.skip(true, 'component not patched — /greenautarky-join did not redirect');

    await page.goto(`${deviceUrl}/greenautarky-join`);
    await expect(page.locator('ga-setup-pin')).toBeAttached({ timeout: 20_000 });

    // In join mode the PIN step forwards ANY 6-digit PIN to the create-user step
    // (it is only verified server-side at submit). Entering it does NOT create
    // anything — we stop before submit, so this stays read-only on the device.
    await page.locator('ga-setup-pin input').first().fill('000000');
    await expect(page.locator('ga-setup-create-user')).toBeAttached({ timeout: 20_000 });

    // Soft-check the reused ha-form: its schema inputs hydrate async and, on the
    // standalone pre-login setup.html, sometimes not at all (no live `hass`).
    // Record the count rather than hard-failing — reaching the step is the
    // stable, meaningful assertion for a read-only run.
    const inputCount = await page.evaluate(() => {
      const cu = document
        .querySelector('ha-panel-greenautarky-setup')
        ?.shadowRoot?.querySelector('ga-setup-create-user') as (HTMLElement & { shadowRoot?: ShadowRoot }) | null;
      if (!cu?.shadowRoot) return 0;
      let n = 0;
      const walk = (root: ParentNode) => {
        root.querySelectorAll('*').forEach((el) => {
          if ((el as HTMLElement).tagName === 'INPUT') n++;
          const sr = (el as HTMLElement & { shadowRoot?: ShadowRoot }).shadowRoot;
          if (sr) walk(sr);
        });
      };
      walk(cu.shadowRoot);
      return n;
    });
    testInfo.annotations.push({ type: 'create-user-inputs', description: String(inputCount) });

    // CONSENT CHECKBOX — tolerate BOTH variants (a parallel change is adding it):
    //   • present  → assert it starts unchecked (opt-in, not pre-ticked).
    //   • absent   → record an expected-next annotation, do not fail.
    const consent = await page.evaluate(() => {
      const panel = document.querySelector('ha-panel-greenautarky-setup');
      const found: { count: number; checked: boolean; label: string } = { count: 0, checked: false, label: '' };
      if (!panel) return found;
      const scan = (root: ParentNode) => {
        root.querySelectorAll('input[type="checkbox"]').forEach((cb) => {
          found.count++;
          if ((cb as HTMLInputElement).checked) found.checked = true;
        });
        const t = (root as HTMLElement).textContent ?? '';
        if (/einwillig|zustimm|consent|datenschutz|akzeptier|einverst/i.test(t)) found.label = 'consent-text';
        root.querySelectorAll('*').forEach((el) => {
          const sr = (el as HTMLElement & { shadowRoot?: ShadowRoot }).shadowRoot;
          if (sr) scan(sr);
        });
      };
      const sr = (panel as HTMLElement & { shadowRoot?: ShadowRoot }).shadowRoot;
      if (sr) scan(sr);
      return found;
    });

    if (consent.count > 0) {
      testInfo.annotations.push({ type: 'consent-checkbox', description: 'present' });
      expect(consent.checked, 'consent checkbox must start unchecked (opt-in)').toBe(false);
    } else {
      testInfo.annotations.push({
        type: 'consent-checkbox',
        description: 'absent — expected-next (parallel work adding it); tolerated',
      });
    }

    // Explicitly do NOT click submit — read-only run, no user created.
    expect(await page.url()).toMatch(/greenautarky-setup\.html/);
  });
});

test.describe('ga-master-card (ADR-0006) — presence', () => {
  const CARD_URL = '/ga_frontend_bundle_first_party/ga-master-card/ga-master-card.js';

  test('first-party card resource is shipped and registers the custom element', async ({ deviceUrl }) => {
    requireDevice();
    const res = await fetch(`${deviceUrl}${CARD_URL}`);
    expect(res.status, 'card JS served by ga_frontend_bundle').toBe(200);
    expect(res.headers.get('content-type') ?? '').toMatch(/javascript/i);
    const body = await res.text();
    expect(body).toContain('customElements.define("ga-master-card"');
    expect(body).toContain('window.customCards');
  });

  test('card element defines in an authenticated frontend (needs HA auth)', async ({ page, deviceUrl }) => {
    requireDevice();
    if (!process.env.HA_TOKEN && !process.env.HA_ADMIN_PASS)
      test.skip(true, 'HA auth (HA_TOKEN/HA_ADMIN_PASS) required — the card injects only in the logged-in app');

    const { haLogin } = await import('../helpers/auth');
    await haLogin(page, deviceUrl);
    await page.goto(`${deviceUrl}/lovelace/0`, { waitUntil: 'domcontentloaded' }).catch(() => {});
    // add_extra_js_url injects the module on app boot; wait for registration.
    await page.waitForFunction(() => !!customElements.get('ga-master-card'), { timeout: 20_000 });
    const listed = await page.evaluate(
      () =>
        Array.isArray((window as unknown as { customCards?: { type: string }[] }).customCards) &&
        (window as unknown as { customCards: { type: string }[] }).customCards.some((c) => /ga-master-card/.test(c.type)),
    );
    expect(listed, 'ga-master-card advertised in window.customCards').toBe(true);
  });
});
