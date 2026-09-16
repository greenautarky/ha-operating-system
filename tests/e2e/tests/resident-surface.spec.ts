import { test, expect } from '../fixtures/device';
import { haLogin } from '../helpers/auth';
import { waitForHA } from '../helpers/ha-api';
import {
  ADVERTISED_CARD_TYPES,
  AXIS_LABELS,
  addressesInText,
  addressLikeLabels,
  expectedElementNames,
  firstPartyAssetIds,
  hasHeatingCard,
  leakedStockPanels,
  missingAdvertisedCards,
  missingElementErrors,
  missingExpectedPanels,
  personalDashboardsInSidebar,
  renderedLabels,
  unmappedAssets,
  unregisteredAssets,
  type CustomCardEntry,
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
 * On the same day, on a FRESHLY FLASHED canary, it was worse: not one
 * first-party card registered at all. `window.customCards` filtered to `ga-*`
 * was empty, `customElements.get('ga-heating-card')` was `false`, the heating
 * plan rendered Home Assistant's red "custom element doesn't exist" card, the
 * "Verwalten" tab did not load. Every card file was fetched and served HTTP 200
 * with its `customElements.define` intact — fetched, never executed. Section 4
 * below is that failure, written down.
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

/** Whether the logged-in user is an admin — decides which stock panels HA offers. */
async function isAdmin(page: import('@playwright/test').Page): Promise<boolean> {
  return page.evaluate(`(() => {
    const hass = (document.querySelector('home-assistant') || {}).hass;
    return !!(hass && hass.user && hass.user.is_admin);
  })()`) as Promise<boolean>;
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
    const admin = await isAdmin(page);

    // `config` and `developer-tools` are admin-only in Home Assistant itself; a
    // resident never had them. Measured on the first resident-account run
    // (K31, rc39, 2026-09-16): the admin-derived list reported both "gone".
    const missing = missingExpectedPanels(all, admin);
    expect(
      missing,
      `Panels a ${admin ? 'admin' : 'resident'} must keep are gone: ${missing.join(', ')}. Present: ` +
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

  // ───────────────────────────────────────────────────────────────────────────
  // 4. Do the cards the bundle ships actually REGISTER?
  //
  // This is the half no server can reach. `ga_manager`'s `ga.frontend_cards`
  // check compares what the bundle SHIPS on disk with what Core REGISTERED and
  // what those URLs SERVE — and on the canary all three of those agreed while
  // the resident looked at a page of red error cards. "The module was delivered
  // and did not execute" is a fact about a JavaScript runtime; only a browser
  // can witness it.
  //
  // The judgements live in `helpers/resident-surface.ts` so that
  // `resident-surface-gate.spec.ts` proves them red and green with fixtures,
  // on every PR, with no device.
  // ───────────────────────────────────────────────────────────────────────────

  test('every card the bundle ships is registered in the browser', async ({
    page,
    deviceUrl,
  }) => {
    await openResidentDashboard(page, deviceUrl);

    // What the page was TOLD to load. There is no filesystem here, so this is
    // "what the bundle ships" as the browser can see it.
    //
    // READ THIS BEFORE SIMPLIFYING IT. Home Assistant does NOT emit
    // `<script type="module" src=...>` for its extra modules — its own index
    // template writes `import("<url>")` inside a plain `<script>` with no
    // `type` attribute at all (frontend `src/html/index.html.template`). A
    // querySelector for module tags returns NOTHING on every device, and a
    // check built on it can neither pass nor fail, which is the most useless
    // shape a check has.
    //
    // So the list is a union of three readings, strongest first:
    //   1. `performance` resource entries — the URLs the browser actually
    //      FETCHED. This is the direct witness of the measured failure:
    //      delivered, and never executed.
    //   2. the `import(...)` calls in the page's own inline scripts.
    //   3. any plain `src=` script, for a proxy that rewrites the page.
    // The three readings arrive in different shapes (absolute vs relative);
    // `modulePath` in the helper normalises them, and the gate proves that.
    const moduleSrcs = (await page.evaluate(`(() => {
      const out = new Set();
      for (const e of performance.getEntriesByType('resource')) out.add(e.name);
      for (const s of Array.from(document.querySelectorAll('script'))) {
        if (s.src) out.add(s.src);
        for (const m of (s.textContent || '').matchAll(
              /\\bimport\\s*\\(\\s*["']([^"']+)["']\\s*\\)/g)) out.add(m[1]);
      }
      return Array.from(out);
    })()`)) as (string | null)[];

    const assets = firstPartyAssetIds(moduleSrcs);

    // Coverage before verdict. A loop over zero assets passes every assertion
    // inside it, and "no first-party module was injected at all" is itself the
    // loudest possible version of this failure — not a pass.
    expect(
      assets.length,
      'The page injected no first-party card module at all. Either ' +
        'ga_frontend_bundle is not set up in Core, or it registered nothing — ' +
        'read the device-side `ga.frontend_cards` check, which compares the ' +
        'shipped directory against the registration and can tell those apart.\n' +
        `Modules the page loaded: ${moduleSrcs.filter(Boolean).slice(0, 40).join(', ')}`,
    ).toBeGreaterThan(0);

    // Fails closed: a card added to the bundle that nobody mapped is a finding,
    // never a silent skip — otherwise this check covers less every release
    // while staying green.
    const unmapped = unmappedAssets(assets);
    expect(
      unmapped,
      `The bundle ships asset(s) this suite has never been told about: ` +
        `${unmapped.join(', ')}. Add each to EXPECTED_ELEMENTS in ` +
        'helpers/resident-surface.ts with the element it defines (or `null` if ' +
        'it is a side-effect module like ga-sidebar-default). Until then they ' +
        'are unchecked.',
    ).toEqual([]);

    const names = expectedElementNames(assets);
    // A real function, not a string: Playwright treats a string as an
    // expression to evaluate and does not pass `names` into it, so the map
    // came back undefined and this test could not pass on any device
    // (first full resident-account run, K31 rc39, 2026-09-16).
    const defined = (await page.evaluate(
      (ns: string[]) => Object.fromEntries(ns.map(n => [n, !!customElements.get(n)])),
      names,
    )) as Record<string, boolean>;

    const unregistered = unregisteredAssets(assets, defined);
    expect(
      unregistered,
      `Card modules delivered and never registered: ${unregistered.join(', ')}.\n` +
        'Each file is served — the browser fetched it — and its ' +
        '`customElements.define` never ran, so every dashboard that names one ' +
        "renders Home Assistant's red \"custom element doesn't exist\" card. " +
        'Nothing on the server side can see this: the file is on disk, it is ' +
        'registered with the frontend, and it answers 200.',
    ).toEqual([]);
  });

  test('the GA cards advertise themselves to the card picker', async ({
    page,
    deviceUrl,
  }) => {
    // A second, INDEPENDENT reading. A card can define its element and forget
    // to push into `window.customCards`: it then renders where a dashboard
    // already names it, and cannot be added to one. `window.customCards`
    // filtered to `ga-*` was empty on the canary, which is what made the
    // failure visible in one line.
    await openResidentDashboard(page, deviceUrl);

    const customCards = (await page.evaluate(
      `(() => (window.customCards || []).map(c => ({ type: c.type, name: c.name })))()`,
    )) as CustomCardEntry[];

    const missing = missingAdvertisedCards(customCards);
    expect(
      missing,
      `GA cards absent from window.customCards: ${missing.join(', ')}.\n` +
        `Everything registered there: ${customCards.map(c => c.type).sort().join(', ') ||
          '(nothing at all)'}\n` +
        'The card picker reads this array, so a card missing here cannot be ' +
        `added to a dashboard. Expected: ${ADVERTISED_CARD_TYPES.join(', ')}.`,
    ).toEqual([]);
  });

  test("no card renders Home Assistant's error element", async ({ page, deviceUrl }) => {
    // The outcome, not the mechanism. The two tests above ask whether the
    // registry is right; this asks what the resident is actually looking at —
    // and it catches causes neither of them models (a card that throws while
    // constructing, a `custom:` type nobody ships at all).
    await openResidentDashboard(page, deviceUrl);

    const deadline = Date.now() + 15_000;
    let read = { errors: 0, texts: [] as string[], total: 0 };
    for (;;) {
      read = (await page.evaluate(`(() => {
        ${DEEP_QUERY}
        const all = deep(document);
        const bad = all.filter(e => e.tagName === 'HUI-ERROR-CARD');
        return {
          errors: bad.length,
          texts: bad.map(e => (e.textContent || '').trim()).filter(Boolean),
          total: all.length,
        };
      })()`)) as { errors: number; texts: string[]; total: number };
      if (read.errors > 0 || read.total > 50 || Date.now() > deadline) break;
      await page.waitForTimeout(500);
    }

    expect(
      read.total,
      'The page rendered almost no elements, so this test read nothing and a ' +
        'pass would mean nothing.',
    ).toBeGreaterThan(50);

    const undefinedElements = missingElementErrors(read.texts);
    expect(
      undefinedElements,
      `Home Assistant reports these custom elements as missing: ` +
        `${undefinedElements.join(', ')}.\n` +
        'This is what the resident sees in place of the card: a red box. ' +
        'Measured on a freshly flashed canary on 2026-09-15, where the heating ' +
        'plan and the Verwalten tab were both this.',
    ).toEqual([]);

    expect(
      read.errors,
      `The dashboard rendered ${read.errors} error card(s): ` +
        `${read.texts.join(' | ')}. A resident sees each of these as a red box ` +
        'where a card belongs.',
    ).toBe(0);
  });
  // ── what a resident MEETS, measured on rc37 and fixed in rc38 ────────────
  //
  // Thomas walked a commissioned flat on 2026-09-15 and listed what was wrong
  // with the screen he was handed. Four of those became code changes; these are
  // the assertions that stop them coming back. Each one failed on rc37 and
  // passes on rc38 — they are not written from the fix, they are written from
  // the complaint.

  test('the card says whether the room is being heated', async ({ page, deviceUrl }) => {
    // MEASURED rc37: the valve was 100 % open and `hvac_action` read `heating`
    // while the card showed the current temperature, the target, and nothing
    // else. The information had reached the browser and was not drawn.
    await openResidentDashboard(page, deviceUrl);

    const state = await page.evaluate(`(() => {
      const hass = (document.querySelector('home-assistant') || {}).hass;
      if (!hass) return null;
      const climates = Object.values(hass.states)
        .filter(s => s.entity_id.startsWith('climate.'));
      return { count: climates.length,
               actions: climates.map(s => s.attributes.hvac_action || s.state) };
    })()`) as { count: number; actions: string[] } | null;

    if (!state || state.count === 0) {
      test.skip(true, 'No climate entity on this device — nothing to say a state about.');
    }

    const deadline = Date.now() + 15_000;
    let badges: string[] = [];
    for (;;) {
      badges = (await page.evaluate(`(() => {
        ${DEEP_QUERY}
        return deep(document)
          .filter(e => (e.className || '').toString().split(' ').includes('act'))
          .map(e => (e.textContent || '').trim())
          .filter(Boolean);
      })()`)) as string[];
      if (badges.length > 0 || Date.now() > deadline) break;
      await page.waitForTimeout(500);
    }

    expect(
      badges,
      'No running-state badge is rendered anywhere. A resident cannot tell a ' +
        'room that is heating from one that has reached its target — the two ' +
        'looked identical on rc37, twelve seconds apart, with the valve fully ' +
        'open in one of them. `hvac_action` is on the entity; it has to reach ' +
        'the screen.',
    ).not.toEqual([]);

    const known = badges.filter(b => ['Heizt', 'Bereit', 'Aus'].includes(b));
    expect(
      known.length,
      `Badges rendered, but none of them says anything a resident reads: ` +
        `${badges.join(' | ')}. A colour alone is not a statement.`,
    ).toBeGreaterThan(0);
  });

  test('the sidebar starts collapsed for a resident', async ({ page, deviceUrl }) => {
    // MEASURED rc37: expanded on every first load, 255 px wide, and no stored
    // preference at all — the asset meant to collapse it fired its event at an
    // element whose listener was not attached yet and reported success, so its
    // retry never ran. "The file was served" is not "the file worked".
    await page.context().clearCookies();
    await openResidentDashboard(page, deviceUrl);
    await page.evaluate(`(() => { try { localStorage.removeItem('dockedSidebar'); } catch (e) {} })()`);
    await page.reload({ waitUntil: 'domcontentloaded' });

    const deadline = Date.now() + 20_000;
    let state: { expanded: boolean; docked: string | null } = { expanded: true, docked: null };
    for (;;) {
      state = (await page.evaluate(`(() => {
        const main = (document.querySelector('home-assistant') || {}).shadowRoot
          ?.querySelector('home-assistant-main');
        let docked = null;
        try { docked = localStorage.getItem('dockedSidebar'); } catch (e) {}
        return { expanded: !!main?.hasAttribute('expanded'), docked };
      })()`)) as typeof state;
      if (!state.expanded || Date.now() > deadline) break;
      await page.waitForTimeout(500);
    }

    expect(
      state.expanded,
      'The sidebar is open on a first load. ga-sidebar-default is supposed to ' +
        'collapse it; being served is not evidence that it ran — the stored ' +
        `preference reads ${JSON.stringify(state.docked)}.`,
    ).toBe(false);
  });

  test('no vendor knob is offered as a resident control', async ({ page, deviceUrl }) => {
    // MEASURED rc37: a Sonoff valve publishes `smart_temperature_control` with
    // `entity_category: None` — the vendor calls it a primary control — so the
    // room offered residents an English, unexplained switch that changes how the
    // valve regulates. Its siblings `child_lock` and `open_window` carry
    // `config` and were filtered: whether a resident saw a vendor knob depended
    // on how the vendor had labelled it (ADR-0014 Amendment 1).
    //
    // Asserted on the RENDERED page rather than on the model, because that is
    // where a resident meets it.
    await openResidentDashboard(page, deviceUrl);

    const furnished = await furnishedAreaCount(page);
    if (furnished === 0) {
      test.skip(true, 'No furnished area on this device — no control list to read.');
    }

    const text = (await page.evaluate(`(() => {
      ${DEEP_QUERY}
      return deep(document)
        .filter(e => !['SCRIPT', 'STYLE'].includes(e.tagName))
        .map(e => Array.from(e.childNodes)
          .filter(n => n.nodeType === 3)
          .map(n => n.textContent)
          .join(' '))
        .join('\\n');
    })()`)) as string;

    expect(
      text.trim().length,
      'The rendered page produced no text at all — a pass here would mean nothing.',
    ).toBeGreaterThan(0);

    // Deliberately a SMALL list of things seen in the field rather than a clever
    // pattern: this test is a tripwire for the allow-list, and a tripwire that
    // tries to be general stops being readable.
    const vendorKnobs = ['Smart temperature control', 'Child lock', 'Open window'];
    const found = vendorKnobs.filter(k => text.toLowerCase().includes(k.toLowerCase()));
    expect(
      found,
      `Vendor controls are on the resident's screen: ${found.join(', ')}. The ` +
        'room view is supposed to offer a chosen set per device role, not ' +
        'everything the hardware happens to expose — the next firmware adds one ' +
        'and nobody decided that it should be there.',
    ).toEqual([]);
  });
});
