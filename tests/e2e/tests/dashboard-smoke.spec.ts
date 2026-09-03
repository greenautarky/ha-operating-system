import * as path from 'path';
import type { Page } from '@playwright/test';
import { test, expect } from '../fixtures/device';
import { haLogin } from '../helpers/auth';
import { waitForHA } from '../helpers/ha-api';

/**
 * Dashboard render smoke — does a dashboard actually DRAW?
 *
 * The resident-ui spec asserts the generated config; this file asserts the
 * DOM, because the two fail differently. A config with the right cards still
 * renders a red "Custom element doesn't exist: ga-thermostat-card" box when
 * the frontend bundle did not load, and only the DOM knows that.
 *
 * Asserted per dashboard, after login as the HA admin:
 *   - `ha-panel-lovelace` is present (the panel booted)
 *   - at least one card element rendered
 *   - no `hui-error-card`
 *   - no element whose own text says "Custom element doesn't exist"
 * and a screenshot lands in test-results/ for a person to look at.
 *
 * Requires credentials: HA_ADMIN_USER + HA_ADMIN_PASSWORD (what
 * run-with-device-secrets.sh exports), HA_ADMIN_PASS, or HA_TOKEN. Skips
 * with the reason when unset, and when the device is still in its wizard.
 */

const PAGE_LOAD_MS = 60_000;
const RENDER_MS = 30_000;
/** greenautarky_site/dashboards.py URL_PREFIX — per-user GA home dashboards. */
const GA_DASHBOARD_PREFIX = 'ga-home';
/** The un-injected placeholder every GA source repo carries (RELEASING.md). */
const DEV_VERSION = '0.0.0.dev0';

function hasAuth(): boolean {
  return Boolean(
    process.env.HA_TOKEN || process.env.HA_ADMIN_PASS || process.env.HA_ADMIN_PASSWORD,
  );
}

function skipIfNoAuth() {
  if (!hasAuth()) {
    test.skip(
      true,
      'Dashboard smoke requires auth — set HA_ADMIN_USER + HA_ADMIN_PASSWORD ' +
        '(tests/e2e/run-with-device-secrets.sh does this) or HA_TOKEN',
    );
  }
}

/** A device whose wizard is unfinished redirects `/` to the setup page. */
async function onboardingIncomplete(deviceUrl: string): Promise<boolean> {
  const res = await fetch(deviceUrl + '/', { redirect: 'manual' });
  return (res.headers.get('location') ?? '').includes('greenautarky-setup');
}

function screenshotPath(name: string): string {
  return path.join(__dirname, '..', 'test-results', name);
}

interface RenderProbe {
  panel: boolean;
  cards: number;
  errorCards: string[];
  missingElements: string[];
}

/**
 * Walk the whole document INCLUDING open shadow roots and report what the
 * Lovelace panel rendered. Shadow DOM is why `page.locator` alone is not
 * enough here: the "Custom element doesn't exist" text lives inside an
 * `ha-alert` inside `hui-error-card` inside `hui-card`, and the message is
 * the one thing that names the missing element.
 */
async function probeLovelace(page: Page): Promise<RenderProbe> {
  return page.evaluate(() => {
    const all: Element[] = [];
    const walk = (root: ParentNode) => {
      for (const el of Array.from(root.querySelectorAll('*'))) {
        all.push(el);
        const sr = (el as HTMLElement & { shadowRoot?: ShadowRoot }).shadowRoot;
        if (sr) walk(sr);
      }
    };
    walk(document);
    const ownText = (el: Element) =>
      Array.from(el.childNodes)
        .filter(n => n.nodeType === Node.TEXT_NODE)
        .map(n => n.textContent ?? '')
        .join('')
        .trim();
    const tags = all.map(e => e.tagName.toLowerCase());
    return {
      panel: tags.includes('ha-panel-lovelace'),
      // `hui-card` is the wrapper newer frontends put around every card;
      // `hui-<type>-card` is the card itself. Either proves a card drew.
      cards: tags.filter(
        t =>
          t === 'hui-card' ||
          (t.startsWith('hui-') && t.endsWith('-card') && t !== 'hui-error-card'),
      ).length,
      errorCards: all
        .filter(e => e.tagName.toLowerCase() === 'hui-error-card')
        .map(e => (e.shadowRoot?.textContent ?? e.textContent ?? '').trim().slice(0, 200)),
      missingElements: all
        .map(ownText)
        .filter(t => t.includes("Custom element doesn't exist")),
    };
  });
}

/** Poll until the panel and at least one card are there, or the deadline. */
async function waitForRender(page: Page, timeoutMs = RENDER_MS): Promise<RenderProbe> {
  const deadline = Date.now() + timeoutMs;
  let probe = await probeLovelace(page);
  while (!(probe.panel && probe.cards > 0) && Date.now() < deadline) {
    await page.waitForTimeout(500);
    probe = await probeLovelace(page);
  }
  return probe;
}

async function assertDashboardRenders(page: Page, url: string, shot: string) {
  await page.goto(url, { timeout: PAGE_LOAD_MS, waitUntil: 'domcontentloaded' });
  const probe = await waitForRender(page);
  await page.screenshot({ path: screenshotPath(shot), fullPage: true });

  expect(probe.panel, `${url}: ha-panel-lovelace never rendered`).toBe(true);
  expect(
    probe.missingElements,
    `${url}: cards whose custom element is not registered (frontend bundle not loaded?)`,
  ).toEqual([]);
  expect(probe.errorCards, `${url}: hui-error-card rendered`).toEqual([]);
  expect(probe.cards, `${url}: no card element rendered`).toBeGreaterThan(0);
}

/** url_path of every GA home dashboard the frontend knows about. */
async function gaDashboardPaths(page: Page): Promise<string[]> {
  return page.evaluate(prefix => {
    const hass = (document.querySelector('home-assistant') as HTMLElement & {
      hass?: { panels?: Record<string, { url_path: string; component_name: string }> };
    })?.hass;
    return Object.values(hass?.panels ?? {})
      .filter(p => p.component_name === 'lovelace' && p.url_path.startsWith(prefix))
      .map(p => p.url_path)
      .sort();
  }, GA_DASHBOARD_PREFIX);
}

test.describe('Dashboard render smoke', () => {
  test.beforeEach(skipIfNoAuth);

  test.beforeEach(async ({ deviceUrl }) => {
    if (await onboardingIncomplete(deviceUrl)) {
      test.skip(
        true,
        'Device is still in the onboarding wizard: / redirects to ' +
          '/greenautarky-setup.html, so there is no dashboard to render yet. ' +
          'Complete onboarding, then re-run — this is not a UI defect.',
      );
    }
  });

  test('/lovelace renders cards and no missing custom elements', async ({
    page,
    deviceUrl,
  }, testInfo) => {
    await waitForHA(deviceUrl);
    await haLogin(page, deviceUrl);
    const shot =
      testInfo.project.name === 'desktop'
        ? 'dashboard-smoke.png'
        : `dashboard-smoke-${testInfo.project.name}.png`;
    await assertDashboardRenders(page, `${deviceUrl}/lovelace`, shot);
  });

  test('every GA home dashboard renders cards and no missing custom elements', async ({
    page,
    deviceUrl,
  }, testInfo) => {
    await waitForHA(deviceUrl);
    await haLogin(page, deviceUrl);
    await page.goto(`${deviceUrl}/lovelace`, {
      timeout: PAGE_LOAD_MS,
      waitUntil: 'domcontentloaded',
    });
    await waitForRender(page);

    const paths = await gaDashboardPaths(page);
    if (paths.length === 0) {
      test.skip(
        true,
        `No dashboard with url_path "${GA_DASHBOARD_PREFIX}*" is registered on this ` +
          'device — the GA home dashboard is created per resident at onboarding, so a ' +
          'device without a resident has none. Nothing to render here.',
      );
    }

    for (const p of paths) {
      const shot =
        testInfo.project.name === 'desktop'
          ? `dashboard-smoke-${p}.png`
          : `dashboard-smoke-${p}-${testInfo.project.name}.png`;
      await assertDashboardRenders(page, `${deviceUrl}/${p}`, shot);
    }
  });
});

/**
 * Version stamping — the wizard's build-id (and Settings > About's Frontend
 * row) must carry the CI CalVer, never the source placeholder.
 *
 * Observed on K31 rc17 (2026-09-01): the wizard footer read
 * `0.0.0.dev0-2d0609e2e`. The greenautarky-setup panel renders
 * `${__VERSION__}-${__GIT_HASH__}` from the frontend build's env.version(),
 * so the placeholder reaching a release image means the injected version
 * never reached the JS bundle. It was marked `test.fail` — an EXPECTED failure
 * — so that it would report as "expected" while broken and turn the suite red
 * the day it passed, forcing the marker out rather than letting it be forgotten.
 * That is exactly what happened: on K31, 2026-09-03, /config/info's Frontend row
 * carried a real CalVer and the marked test reported "Expected to fail, but
 * passed". The marker is gone; this is an ordinary assertion now, and a
 * regression here is a plain failure.
 */
test.describe('Frontend version stamping', () => {
  test('rendered frontend version is not the 0.0.0.dev0 placeholder', async ({
    page,
    deviceUrl,
  }) => {
    await waitForHA(deviceUrl);
    let rendered = '';
    let where = '';

    // 1. Pre-onboarding: the wizard footer carries the build-id link.
    const wizard = await page.goto(`${deviceUrl}/greenautarky-setup.html`, {
      timeout: PAGE_LOAD_MS,
      waitUntil: 'domcontentloaded',
    });
    if (wizard && wizard.ok()) {
      const buildId = page.locator('ha-panel-greenautarky-setup .build-id');
      if (await buildId.count()) {
        rendered = (await buildId.first().innerText({ timeout: RENDER_MS })).trim();
        where = '/greenautarky-setup.html footer build-id';
      }
    }

    // 2. Post-onboarding the panel is gone; Settings > About shows the same
    //    __VERSION__ in its Frontend row (admin only).
    if (!rendered) {
      if (!hasAuth()) {
        test.skip(
          true,
          'Wizard page not served and no auth to open /config/info — set ' +
            'HA_ADMIN_USER + HA_ADMIN_PASSWORD to read the Frontend version there',
        );
      }
      await haLogin(page, deviceUrl);
      await page.goto(`${deviceUrl}/config/info`, {
        timeout: PAGE_LOAD_MS,
        waitUntil: 'domcontentloaded',
      });
      const row = page.locator('ha-config-info li', { hasText: /Frontend/ }).locator('.version');
      rendered = (await row.first().innerText({ timeout: RENDER_MS })).trim();
      where = '/config/info Frontend row';
    }

    expect(rendered, `no version string found at ${where}`).not.toBe('');
    expect(
      rendered,
      `${where} shows the un-injected placeholder "${rendered}" — the CI CalVer ` +
        '(YYYYMMDD.N, see RELEASING.md) never reached the frontend JS bundle',
    ).not.toMatch(new RegExp(`^${DEV_VERSION.replace(/\./g, '\\.')}`));
  });
});
