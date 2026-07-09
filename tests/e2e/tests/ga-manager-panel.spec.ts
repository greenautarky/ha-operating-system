import { test, expect } from '@playwright/test';

/**
 * ga_manager local status panel — API + Playwright E2E (addon 0.74.0)
 *
 * The panel is served by the ga_manager addon on port :8099 (NOT the HA
 * frontend on :8123), so this spec does NOT use the device fixture / baseURL.
 * It targets the panel directly over the mesh and authenticates with the
 * addon's Bearer token.
 *
 * REQUIRES:
 *   GA_PANEL_URL    — panel base, e.g. http://100.126.91.112:8099 (K17 over mesh)
 *   GA_PANEL_TOKEN  — Bearer token. On the device:
 *                       docker exec <ga_manager container> cat /data/auth.token
 *                     (mode 0600; rotate via `rm /data/auth.token && ha addons restart`).
 *                     A request carrying an `X-Ingress-Path` header bypasses the
 *                     Bearer check (Supervisor Ingress path) — direct :8099 access
 *                     needs the token.
 *
 * Auto-skips if either env var is unset.
 *
 * CONTRACT NOTE (verified live on K17 / rc19, 2026-07-09):
 *   The panel splits version data across THREE endpoints — do NOT expect
 *   OS/Supervisor/Core/addons or `component_versions` on /health:
 *     - GET /health   → health rollup: timestamp, device_id, overall, phase,
 *                       checks[], errors[] (+ led, tick_count). NO versions.
 *     - GET /versions → os / supervisor / core / frontend / addons[] / ga_manager.
 *     - GET /info     → component_versions {domain: version} (vendored components).
 *   The rendered HTML `/` Versions card DOES list OS/Supervisor/Core/addons.
 *
 * Run:
 *   GA_PANEL_URL=http://100.126.91.112:8099 GA_PANEL_TOKEN=... \
 *     npx playwright test tests/ga-manager-panel.spec.ts --project=desktop
 */

const PANEL = process.env.GA_PANEL_URL?.replace(/\/$/, '') || '';
const TOKEN = process.env.GA_PANEL_TOKEN || '';

function skipGuards() {
  if (!PANEL) test.skip(true, 'GA_PANEL_URL required (e.g. http://100.126.91.112:8099)');
  if (!TOKEN) test.skip(true, 'GA_PANEL_TOKEN required — device /data/auth.token');
}

const authHeaders = () => ({ Authorization: `Bearer ${TOKEN}` });

// -------------------------------------------------------------------------
// API tests — curl-level, no browser
// -------------------------------------------------------------------------
test.describe('ga_manager panel — API', () => {
  test('liveness/readiness probes are unauthenticated 200', async () => {
    skipGuards();
    for (const p of ['/livez', '/readyz']) {
      const res = await fetch(`${PANEL}${p}`);
      expect(res.status, `${p} should be public 200`).toBe(200);
    }
  });

  test('/health requires auth (401 without Bearer)', async () => {
    skipGuards();
    const res = await fetch(`${PANEL}/health`);
    expect(res.status).toBe(401);
    expect(res.headers.get('www-authenticate') ?? '').toMatch(/Bearer/i);
  });

  test('/health returns the health rollup shape', async () => {
    skipGuards();
    const res = await fetch(`${PANEL}/health`, { headers: authHeaders() });
    expect(res.status).toBe(200);
    const j = await res.json();
    // Health rollup — the documented top-level keys.
    expect(j).toHaveProperty('timestamp');
    expect(j).toHaveProperty('device_id');
    expect(typeof j.device_id).toBe('string');
    expect(['ok', 'warn', 'crit', 'unknown']).toContain(j.overall);
    expect(typeof j.phase).toBe('string');
    expect(Array.isArray(j.checks), 'checks[] present').toBe(true);
    // Contract guard: versions are intentionally NOT on /health.
    expect(j).not.toHaveProperty('component_versions');
  });

  test('/versions lists OS, Supervisor, Core and addons (component_versions home #1)', async () => {
    skipGuards();
    const res = await fetch(`${PANEL}/versions`, { headers: authHeaders() });
    expect(res.status).toBe(200);
    const j = await res.json();
    for (const layer of ['os', 'supervisor', 'core']) {
      expect(j, `versions.${layer} present`).toHaveProperty(layer);
      expect(typeof j[layer]?.version, `${layer}.version is a string`).toBe('string');
    }
    // addons is a slug-keyed object {slug: {name, version, state, …}}, not an array.
    expect(typeof j.addons, 'addons map present').toBe('object');
    expect(Object.keys(j.addons ?? {}).length, 'at least one addon reported').toBeGreaterThan(0);
    expect(j).toHaveProperty('ga_manager');
  });

  test('/info exposes component_versions map (component_versions home #2)', async () => {
    skipGuards();
    const res = await fetch(`${PANEL}/info`, { headers: authHeaders() });
    expect(res.status).toBe(200);
    const j = await res.json();
    expect(j).toHaveProperty('component_versions');
    expect(typeof j.component_versions).toBe('object');
    expect(j).toHaveProperty('device_id');
  });
});

// -------------------------------------------------------------------------
// Playwright tests — render the HTML status page
// The panel needs the Bearer token on the HTML request too, so inject it as
// a context-level header.
// -------------------------------------------------------------------------
test.describe('ga_manager panel — HTML status page', () => {
  test.use({ extraHTTPHeaders: { Authorization: `Bearer ${process.env.GA_PANEL_TOKEN || ''}` } });

  test('root page loads as authenticated HTML', async ({ page }) => {
    skipGuards();
    const res = await page.goto(`${PANEL}/`, { waitUntil: 'domcontentloaded' });
    expect(res?.status()).toBe(200);
    expect((res?.headers()['content-type'] ?? '')).toContain('text/html');
    // Header banner is <h1>GA Manager <span class="device-id">…</span></h1>
    await expect(page.getByRole('heading', { level: 1 })).toContainText(/GA Manager/i);
  });

  test('sections render in order Overall → Identity → Versions → Features → Network → Zigbee', async ({
    page,
  }) => {
    skipGuards();
    await page.goto(`${PANEL}/`, { waitUntil: 'domcontentloaded' });

    // Overall is the first card (a state badge, NO <h2>). Assert it precedes
    // the first <h2>.
    await expect(page.locator('section.card.overall')).toBeVisible();

    // The <h2> texts in DOM order are the stable section markers (no ids/classes).
    const headings = await page.locator('h2').allTextContents();
    const norm = headings.map((h) => h.trim());
    const idx = (name: string) => norm.findIndex((h) => h === name);

    // Required, always-rendered sections in the expected relative order.
    expect(idx('Identity'), 'Identity section present').toBeGreaterThanOrEqual(0);
    expect(idx('Versions'), 'Versions section present').toBeGreaterThan(idx('Identity'));
    expect(idx('Features'), 'Features section present').toBeGreaterThan(idx('Versions'));

    // Network + Zigbee are conditionally rendered; when present they must
    // follow Features (and precede the Master Users section).
    for (const cond of ['Network', 'Zigbee']) {
      const i = idx(cond);
      if (i >= 0) expect(i, `${cond} after Features`).toBeGreaterThan(idx('Features'));
    }
  });

  test('Versions block lists OS, Supervisor, Core and Addons', async ({ page }) => {
    skipGuards();
    await page.goto(`${PANEL}/`, { waitUntil: 'domcontentloaded' });

    const versionsCard = page.locator('section.card', {
      has: page.getByRole('heading', { name: 'Versions' }),
    });
    await expect(versionsCard).toBeVisible();
    const body = (await versionsCard.textContent()) ?? '';
    expect(body).toContain('OS (HAOS)');
    expect(body).toContain('Supervisor');
    expect(body).toContain('HA Core');
    expect(/Addons \(\d+\)/.test(body), 'Addons (N) row present').toBe(true);
  });

  test('Features rollup renders with state pills', async ({ page }) => {
    skipGuards();
    await page.goto(`${PANEL}/`, { waitUntil: 'domcontentloaded' });

    const featuresCard = page.locator('section.card', {
      has: page.getByRole('heading', { name: 'Features' }),
    });
    await expect(featuresCard).toBeVisible();
    // The rollup lists Onboarding / Vendored integrations / Phase etc. with
    // <span class="state-badge state-{ok|warn|crit|unknown}"> pills.
    const body = (await featuresCard.textContent()) ?? '';
    expect(/Onboarding|Vendored|Phase/i.test(body), 'a known feature row rendered').toBe(true);
    await expect(featuresCard.locator('span.state-badge').first()).toBeVisible();
  });
});
