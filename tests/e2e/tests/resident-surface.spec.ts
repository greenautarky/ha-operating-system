import { test, expect } from '../fixtures/device';
import { haLogin } from '../helpers/auth';
import { waitForHA } from '../helpers/ha-api';
import {
  AXIS_LABELS,
  addressesInText,
  addressLikeLabels,
  hasHeatingCard,
  leakedStockPanels,
  missingExpectedPanels,
  personalDashboardsInSidebar,
  renderedLabels,
  type DashboardConfig,
  type PanelInfo,
} from '../helpers/resident-surface';

/**
 * The surface a resident READS — the sidebar, the device names, the heating plan.
 *
 * `resident-ui.spec.ts` next door asks whether the dashboard was BUILT: rooms,
 * thermostats, non-empty views. It never asks what any of it SAYS. On
 * 2026-09-15 a canary was measured in a browser, logged in as the resident
 * account the wizard creates, and everything that suite checks was green while:
 *
 *   - the sidebar still carried two stock Home Assistant panels (`map`, `todo`)
 *     that a component has been removing since the day it was written — plus
 *     one panel named after the resident's own username;
 *   - devices were listed by their 16-hex-digit Zigbee address, which for a
 *     resident is a serial number where a name belongs;
 *   - the heating plan's day curve carried the hour ONLY in a `title`
 *     attribute — a hover tooltip, i.e. nothing at all on a phone.
 *
 * None of that is cosmetic and nothing looked at any of it. This file does.
 *
 * READ BEFORE EDITING — two guards inherited from `resident-ui.spec.ts`, both
 * paid for on real devices, and one decision that is new here.
 *
 * 1. THE RENDERED CONFIG IS A PRECONDITION. HA's frontend gets its state over
 *    `/api/websocket`; without it the page renders nothing and every assertion
 *    below fails for a reason that has nothing to do with the UI. Measuring
 *    through an SSH tunnel that dropped WebSockets produced a perfect
 *    imitation of a broken UI for several minutes (2026-08-25).
 *
 * 2. A DEVICE WITH NO PAIRED HARDWARE PROVES NOTHING HERE. Zero furnished areas
 *    means the strategy correctly builds no room views; asserting into that is
 *    a permanent red everybody learns to ignore, which is worse than a skip
 *    that names the reason.
 *
 * 3. NEW: the sidebar is read from `hass.panels`, NOT from the rendered
 *    `ha-sidebar`. `ga-sidebar-default.js` docks the sidebar `always_hidden` on
 *    first load (a deliberate resident-clean default), so the drawer's DOM is
 *    not a dependable place to read this — green there could mean "nothing
 *    leaked" or "the drawer is closed", and those must not look alike.
 *    `hass.panels` is the same data the frontend builds the sidebar from, HA's
 *    own filter is applied to it (see `helpers/resident-surface.ts`), and it is
 *    what was measured on the canary.
 *
 * The judgements themselves live in `helpers/resident-surface.ts` so that
 * `resident-surface-gate.spec.ts` can prove them red and green WITHOUT a
 * device, on every PR. A pasted failure is evidence once, about one version;
 * fixtures are evidence every time.
 *
 * Requires credentials for a RESIDENT account (not the admin owner):
 *   HA_ADMIN_USER / HA_ADMIN_PASS, or HA_TOKEN.
 *
 * NOT destructive: nothing here resets onboarding or restarts Core, so nothing
 * here touches (or needs) the `RESET_ONBOARDING` gate in `fixtures/device.ts`.
 */

function skipIfNoAuth() {
  if (!process.env.HA_TOKEN && !process.env.HA_ADMIN_PASS && !process.env.HA_ADMIN_PASSWORD) {
    test.skip(
      true,
      'Resident surface tests require auth — set HA_TOKEN or HA_ADMIN_USER + HA_ADMIN_PASS',
    );
  }
}

/** Every element on the page, shadow roots included. */
const DEEP_QUERY = `
  const deep = (root, out = []) => {
    for (const el of Array.from(root.querySelectorAll('*'))) {
      out.push(el);
      if (el.shadowRoot) deep(el.shadowRoot, out);
    }
    return out;
  };
`;

async function renderedConfig(
  page: import('@playwright/test').Page,
): Promise<DashboardConfig | null> {
  return page.evaluate(`(() => {
    ${DEEP_QUERY}
    const panel = deep(document).find(
      e => e.tagName === 'HUI-ROOT' || e.tagName === 'HA-PANEL-LOVELACE');
    return (panel && panel.lovelace && panel.lovelace.config) || null;
  })()`) as Promise<DashboardConfig | null>;
}

/**
 * The rendered config, waited for rather than slept for.
 *
 * Measured on a bench device 2026-08-27: the panel needed SIX seconds — the
 * frontend lands on the default dashboard path, then swaps to the resident's
 * own, and the element only carries a config after that second navigation
 * settles. A fixed sleep cannot be right: too short is a false alarm about the
 * wrong subsystem, too long is dead time on every green run.
 */
async function waitForRenderedConfig(
  page: import('@playwright/test').Page,
  timeoutMs = 30_000,
): Promise<DashboardConfig | null> {
  const deadline = Date.now() + timeoutMs;
  let cfg = await renderedConfig(page);
  while (cfg === null && Date.now() < deadline) {
    await page.waitForTimeout(500);
    cfg = await renderedConfig(page);
  }
  return cfg;
}

async function panels(page: import('@playwright/test').Page): Promise<PanelInfo[]> {
  return page.evaluate(`(() => {
    const root = document.querySelector('home-assistant');
    const hass = root && root.hass;
    if (!hass || !hass.panels) return [];
    return Object.values(hass.panels).map(p => ({
      url_path: p.url_path, title: p.title || null, component_name: p.component_name,
    }));
  })()`) as Promise<PanelInfo[]>;
}

/** How many areas hold at least one entity the room strategy could show. */
async function furnishedAreaCount(page: import('@playwright/test').Page): Promise<number> {
  return page.evaluate(`(() => {
    const hass = (document.querySelector('home-assistant') || {}).hass;
    if (!hass) return 0;
    const areas = Object.values(hass.areas || {});
    const entities = Object.values(hass.entities || {});
    const devices = Object.values(hass.devices || {});
    return areas.filter(a => entities.some(e =>
      e.area_id === a.area_id ||
      (!e.area_id && devices.some(d => d.id === e.device_id && d.area_id === a.area_id))
    )).length;
  })()`) as Promise<number>;
}

/** Is this device still in the onboarding wizard? Then there is no resident. */
async function onboardingIncomplete(deviceUrl: string): Promise<boolean> {
  const res = await fetch(deviceUrl + '/', { redirect: 'manual' });
  return (res.headers.get('location') ?? '').includes('greenautarky-setup');
}

async function openResidentDashboard(
  page: import('@playwright/test').Page,
  deviceUrl: string,
): Promise<DashboardConfig | null> {
  await waitForHA(deviceUrl);
  await haLogin(page, deviceUrl);
  await page.goto(deviceUrl);
  await page.waitForURL(/lovelace|ga-home/, { timeout: 30_000 });
  const cfg = await waitForRenderedConfig(page);
  expect(
    cfg,
    'No dashboard config: the frontend never connected (check reverse proxies ' +
      'and tunnels). Every assertion in this file would fail for that reason, ' +
      'not because the resident surface is wrong — see resident-ui.spec.ts.',
  ).not.toBeNull();
  return cfg;
}

test.describe('Resident surface', () => {
  test.beforeEach(skipIfNoAuth);

  test.beforeEach(async ({ deviceUrl }) => {
    if (await onboardingIncomplete(deviceUrl)) {
      test.skip(
        true,
        'Device is still in the onboarding wizard: / redirects to ' +
          '/greenautarky-setup.html, so there is no resident and no dashboard ' +
          'to read. Complete onboarding, then re-run. NOT a defect — the ' +
          'onboarding suite asserts the same redirect as a pass.',
      );
    }
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 1. The sidebar
  // ───────────────────────────────────────────────────────────────────────────

  test('no stock Home Assistant panel reaches the resident sidebar', async ({
    page,
    deviceUrl,
  }) => {
    await openResidentDashboard(page, deviceUrl);
    const all = await panels(page);

    // Coverage before verdict: a filter over zero panels is empty, and an empty
    // result is exactly what "healthy" looks like here.
    expect(
      all.length,
      'hass.panels is empty — the frontend has no panel list at all, so this ' +
        'test could only produce a meaningless pass.',
    ).toBeGreaterThan(0);

    const leaked = leakedStockPanels(all);
    expect(
      leaked,
      `Stock HA panels in the resident's sidebar: ${leaked.join(', ')}.\n` +
        `Everything the frontend knows about: ${all
          .map(p => `${p.url_path}${p.title ? '' : ' (no title → hidden)'}`)
          .sort()
          .join(', ')}\n` +
        'These are removed by greenautarky_site. Two of them, `todo` and `map`, ' +
        "are registered when HOME ASSISTANT's own onboarding completes — which " +
        'on a GA device is during our wizard, after every start-up hook has ' +
        'run. If they are back, the component is no longer maintaining the ' +
        'invariant (or Core renamed a panel, which the component cannot see).',
    ).toEqual([]);
  });

  test('the personal dashboard is not a sidebar entry', async ({ page, deviceUrl }) => {
    await openResidentDashboard(page, deviceUrl);
    const all = await panels(page);

    // Not an assertion about whether personal boards exist — a device may have
    // none. It is an assertion about the ones that do.
    const shown = personalDashboardsInSidebar(all);
    expect(
      shown,
      `Personal dashboards in the sidebar: ${shown.join(', ')}. A resident ` +
        'should not find their own username sitting there as a second ' +
        'dashboard; the board stays reachable at its URL and is managed from ' +
        'the master console.',
    ).toEqual([]);
  });

  test('the panels a resident SHOULD have are still there', async ({ page, deviceUrl }) => {
    // Must-not-flag, and it lives next to the leak test on purpose: a sweep
    // that empties the sidebar gets overridden by reflex, which is a slower
    // way of having no sweep at all.
    await openResidentDashboard(page, deviceUrl);
    const all = await panels(page);

    const missing = missingExpectedPanels(all);
    expect(
      missing,
      `Panels a resident must keep are gone: ${missing.join(', ')}. Present: ` +
        `${all.map(p => p.url_path).sort().join(', ')}`,
    ).toEqual([]);
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 2. Device names
  // ───────────────────────────────────────────────────────────────────────────

  test('no device is shown by its raw radio address', async ({ page, deviceUrl }) => {
    const cfg = await openResidentDashboard(page, deviceUrl);

    const furnished = await furnishedAreaCount(page);
    if (furnished === 0) {
      test.skip(
        true,
        'No area on this device holds a single entity, so there is no device ' +
          'list to read. Pair at least one device to an area first.',
      );
    }

    const labels = renderedLabels(cfg);
    expect(
      labels.length,
      'The dashboard config carries no labels at all — a loop over zero labels ' +
        'passes every assertion inside it, which is how a broken board reports ' +
        'itself as healthy.',
    ).toBeGreaterThan(0);

    const serials = addressLikeLabels(labels);
    expect(
      serials,
      `Devices shown by their Zigbee address rather than a name: ${serials.join(', ')}.\n` +
        'For a resident that is a serial number. The ga-home strategy derives a ' +
        'readable label (ga-frontend-bundle, humanLabel) — if these are back, ' +
        'either a card is being built without a name again, or the model carries ' +
        'entities the naming path does not cover.',
    ).toEqual([]);
  });

  test('the visible page carries no radio address either', async ({ page, deviceUrl }) => {
    // The config is what WE build; this is what the resident's eyes land on.
    // They can differ — a card that ignores its `name`, a badge, a more-info
    // dialog title all render from the entity's own friendly_name.
    await openResidentDashboard(page, deviceUrl);

    const furnished = await furnishedAreaCount(page);
    if (furnished === 0) {
      test.skip(true, 'No furnished area on this device — nothing rendered to read.');
    }

    // Cards mount after the config lands. Poll instead of sleeping.
    const deadline = Date.now() + 15_000;
    let text = '';
    let offenders: string[] = [];
    for (;;) {
      text = (await page.evaluate(`(() => {
        ${DEEP_QUERY}
        return deep(document)
          .filter(e => !['SCRIPT', 'STYLE'].includes(e.tagName))
          .map(e => Array.from(e.childNodes)
            .filter(n => n.nodeType === 3)
            .map(n => n.textContent)
            .join(' '))
          .join('\\n');
      })()`)) as string;
      offenders = addressesInText(text);
      if ((offenders.length === 0 && text.trim()) || Date.now() > deadline) break;
      await page.waitForTimeout(500);
    }

    expect(
      text.trim().length,
      'The rendered page produced no text at all — nothing was read, so a pass ' +
        'here would mean nothing.',
    ).toBeGreaterThan(0);

    expect(
      offenders,
      `Radio addresses visible on the resident's dashboard: ${offenders.join(', ')}`,
    ).toEqual([]);
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 3. The heating plan's time axis
  // ───────────────────────────────────────────────────────────────────────────

  test('the heating plan has a readable time axis', async ({ page, deviceUrl }) => {
    const cfg = await openResidentDashboard(page, deviceUrl);

    if (!hasHeatingCard(cfg)) {
      test.skip(
        true,
        'No room on this device has a climate entity, so the strategy builds ' +
          'no Heizplan card. Pair a thermostat to an area first. NOT a defect ' +
          '— and deliberately separated from a real failure, because a ' +
          'permanent red on bench units is the colour people stop reading.',
      );
    }

    // The card renders into its own LIGHT dom but sits inside the dashboard's
    // shadow roots — so it has to be found deep and read shallow.
    const deadline = Date.now() + 20_000;
    let axis: string[] = [];
    let bars = 0;
    for (;;) {
      const read = (await page.evaluate(`(() => {
        ${DEEP_QUERY}
        const card = deep(document).find(e => e.tagName === 'GA-HEATING-CARD');
        if (!card) return null;
        return {
          axis: Array.from(card.querySelectorAll('.axis span'))
            .map(s => (s.textContent || '').trim()),
          bars: card.querySelectorAll('.curve div').length,
        };
      })()`)) as { axis: string[]; bars: number } | null;
      if (read) {
        axis = read.axis;
        bars = read.bars;
      }
      if (axis.length || Date.now() > deadline) break;
      await page.waitForTimeout(500);
    }

    expect(
      bars,
      'The heating card rendered no day curve at all. Either the plan endpoint ' +
        'failed (`/api/ga_heating/schedule`) or the card never mounted — read ' +
        'the browser console before reading this as a missing axis.',
    ).toBeGreaterThan(0);

    expect(
      axis,
      `The heating plan's day curve has no time axis (found: ${JSON.stringify(axis)}).\n` +
        "The hour used to live ONLY in each bar's `title` attribute — a hover " +
        'tooltip, which does not exist on the phone a resident uses, so the ' +
        'curve was an abstract shape. If this is empty again, the labels have ' +
        'been dropped or moved back into an attribute.',
    ).toEqual([...AXIS_LABELS]);
  });

  test('a bar carries its value so a tap can show it', async ({ page, deviceUrl }) => {
    const cfg = await openResidentDashboard(page, deviceUrl);

    if (!hasHeatingCard(cfg)) {
      test.skip(true, 'No climate entity on this device — no Heizplan card.');
    }

    const readout = (await page.evaluate(`(async () => {
      ${DEEP_QUERY}
      const card = deep(document).find(e => e.tagName === 'GA-HEATING-CARD');
      if (!card) return null;
      const bar = card.querySelector('.curve div');
      if (!bar) return null;
      bar.click();
      await new Promise(r => setTimeout(r, 200));
      const el = card.querySelector('.readout');
      return { text: ((el && el.textContent) || '').trim(), hour: bar.dataset.h,
               temp: bar.dataset.t };
    })()`)) as { text: string; hour?: string; temp?: string } | null;

    expect(readout, 'the heating card never mounted').not.toBeNull();
    expect(
      readout?.temp,
      'A bar carries no setpoint, so tapping it can show nothing. On a touch ' +
        'device that leaves the value unreachable — which is the whole defect.',
    ).toBeTruthy();
    expect(
      readout?.text,
      `Tapping a bar produced no readout (hour=${readout?.hour}, temp=${readout?.temp})`,
    ).toContain('°C');
  });
});
