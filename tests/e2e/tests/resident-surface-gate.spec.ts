/**
 * Fixtures for the resident-surface checks — must-flag and must-not-flag.
 *
 * `resident-surface.spec.ts` can only run against a real device. That makes its
 * assertions unprovable on the day they are written and unre-provable every day
 * after: a failure pasted into a review is evidence ONCE, about one version,
 * and nothing re-checks it when the check is edited a month later.
 *
 * So the judgements live in `helpers/resident-surface.ts` as functions over
 * data, and this file runs them against inputs they MUST flag and inputs they
 * must NOT flag. No device, no auth, no network — it runs on every PR, and it
 * is what makes those checks trustworthy between device runs.
 *
 * Three things make that real, and dropping any one turns it into theatre:
 *
 *  (a) MUST-NOT-FLAG IS NOT PADDING. A check that flags everything gets
 *      overridden by reflex, which is a slower way of having no check at all.
 *      Each healthy fixture below is a case that a plausible over-broad
 *      implementation WOULD flag: a hidden personal board, a room called
 *      "Bad 2", a device somebody named.
 *  (b) IT READS THE LIVE DEFINITION. Everything is imported from
 *      `helpers/resident-surface.ts` — the same module the device spec uses.
 *      A self-test that re-declares the patterns tests a copy, stays green
 *      while the real check rots, and is the exact failure class it exists to
 *      catch.
 *  (c) THE SHAPES ARE PINNED. A dashboard config nests cards inside `sections`
 *      and inside `grid` cards; a label can be a view title, a card name, a
 *      card title, or a row inside an `entities` card. Each of those is a place
 *      a serial number can surface, so each is a fixture.
 *
 * Same pattern, and the same reason, as `destructive-fixture-gate.spec.ts`:
 * neither can touch a device.
 */
import { expect, test } from '@playwright/test';

import {
  ADVERTISED_CARD_TYPES,
  AXIS_LABELS,
  EXPECTED_ELEMENTS,
  FIRST_PARTY_URL_BASE,
  addressesInText,
  addressLikeLabels,
  allCards,
  expectedElementNames,
  firstPartyAssetIds,
  modulePath,
  hasHeatingCard,
  leakedStockPanels,
  missingAdvertisedCards,
  missingElementErrors,
  missingExpectedPanels,
  personalDashboardsInSidebar,
  renderedLabels,
  sidebarPanels,
  unmappedAssets,
  unregisteredAssets,
  type DashboardConfig,
  type PanelInfo,
} from '../helpers/resident-surface';

const IEEE = '0x00124b00294cf4a1';

/** A resident's panel list on a device where the sweep is doing its job. */
const HEALTHY_PANELS: PanelInfo[] = [
  { url_path: 'lovelace', title: 'Übersicht' },
  { url_path: 'config', title: 'Einstellungen' },
  { url_path: 'developer-tools', title: 'Entwicklerwerkzeuge' },
  { url_path: 'profile', title: 'Benutzer' },
  // Registered so the URL resolves, deliberately title-less so it is not a
  // sidebar entry. A check that asked "does this panel EXIST" would flag it.
  { url_path: 'ga-home-anna', title: null },
  { url_path: 'greenautarky-setup-panel', title: 'Einrichtung' },
];

test.describe('resident-surface checks: must-flag', () => {
  test('a stock panel in the sidebar is flagged, by name', () => {
    const leaked = leakedStockPanels([
      ...HEALTHY_PANELS,
      { url_path: 'todo', title: 'To-do-Listen' },
      { url_path: 'map', title: 'Karte' },
    ]);
    expect(leaked.sort()).toEqual(['map ("Karte")', 'todo ("To-do-Listen")']);
  });

  test('every one of the six stock panels is flagged, not just the famous two', () => {
    // Coverage, not exit code. `map` and `todo` were the ones measured; a check
    // that silently only covered those would look identical on that device.
    for (const name of ['energy', 'logbook', 'history', 'media-browser', 'todo', 'map']) {
      expect(
        leakedStockPanels([...HEALTHY_PANELS, { url_path: name, title: 'X' }]),
        `${name} is not covered by the stock-panel check`,
      ).toEqual([`${name} ("X")`]);
    }
  });

  test('a personal dashboard with a sidebar title is flagged', () => {
    expect(
      personalDashboardsInSidebar([
        ...HEALTHY_PANELS,
        { url_path: 'ga-home-max', title: 'Max' },
      ]),
    ).toEqual(['ga-home-max ("Max")']);
  });

  test('a missing resident panel is flagged', () => {
    const withoutConfig = HEALTHY_PANELS.filter(p => p.url_path !== 'config');
    expect(missingExpectedPanels(withoutConfig)).toEqual(['config']);
  });

  test('a radio address is flagged wherever a label can hide', () => {
    // Each of these is a real place the strategy puts text in front of a
    // resident, and each was reachable by the defect.
    const cfg: DashboardConfig = {
      views: [
        { title: `Raum ${IEEE}`, cards: [] },
        { title: 'Küche', cards: [{ type: 'tile', name: IEEE }] },
        { title: 'Bad', sections: [{ cards: [{ type: 'tile', name: `${IEEE} l1` }] }] },
        { title: 'Flur', cards: [{ type: 'grid', cards: [{ type: 'tile', title: IEEE }] }] },
        {
          title: 'Keller',
          cards: [{ type: 'entities', entities: [{ entity: 'light.x', name: IEEE }] }],
        },
      ],
    };
    expect(addressLikeLabels(renderedLabels(cfg))).toHaveLength(5);
  });

  test('an address without the 0x prefix is flagged too', () => {
    expect(addressLikeLabels(['00124b00294cf4a1'])).toEqual(['00124b00294cf4a1']);
  });

  test('an address in the rendered page text is flagged', () => {
    expect(addressesInText(`Wohnzimmer\n${IEEE} 21 °C`)).toEqual([IEEE]);
  });

  test('the same address twice is one finding, not two', () => {
    // Identical symptoms are one cause. A list that repeats itself reads as a
    // bigger problem than it is and buries the second, different one.
    expect(addressesInText(`${IEEE} ${IEEE}`)).toEqual([IEEE]);
  });
});

test.describe('resident-surface checks: must-NOT-flag', () => {
  test('a healthy panel list is clean on all three sidebar checks', () => {
    expect(leakedStockPanels(HEALTHY_PANELS)).toEqual([]);
    expect(personalDashboardsInSidebar(HEALTHY_PANELS)).toEqual([]);
    expect(missingExpectedPanels(HEALTHY_PANELS)).toEqual([]);
  });

  test('a personal board that is correctly hidden is not flagged', () => {
    // This is the fix itself: registered (so the URL resolves), title-less (so
    // the sidebar skips it). Flagging it would make the check demand that the
    // board be deleted.
    expect(sidebarPanels(HEALTHY_PANELS).map(p => p.url_path)).not.toContain('ga-home-anna');
    expect(personalDashboardsInSidebar(HEALTHY_PANELS)).toEqual([]);
  });

  test('ordinary German room and device names are not addresses', () => {
    expect(
      addressLikeLabels([
        'Wohnzimmer',
        'Bad 2',
        'Stehlampe',
        'Küchen-Decke_2',
        'Temperatur',
        'Heizplan',
        'Übersicht',
      ]),
    ).toEqual([]);
  });

  test('hex-ish text that is not a 16-digit address is not flagged', () => {
    // The check must not become "anything with hex letters in it". `deadbeef`
    // is 8 digits; `abcdef0123456789ab` is 18; `c0ffee` is a word people use.
    expect(
      addressLikeLabels([
        'deadbeef',
        'abcdef0123456789ab',
        'c0ffee',
        'Sensor 1234567890',
        '2026-09-15',
      ]),
    ).toEqual([]);
  });

  test('a normal page text carries no findings', () => {
    expect(
      addressesInText('Wohnzimmer 21 °C\nHeizplan\nStehlampe\nTemperatur 22,5'),
    ).toEqual([]);
  });

  test('a dashboard with no heating card is recognised as such, not as broken', () => {
    // The device spec SKIPS on this rather than failing — a bench unit with no
    // thermostat is not a defect. If this ever returned true, that skip would
    // turn into a permanent red on every bench device.
    expect(hasHeatingCard({ views: [{ title: 'Küche', cards: [{ type: 'tile' }] }] })).toBe(
      false,
    );
    expect(hasHeatingCard(null)).toBe(false);
  });

  test('a heating card nested in a section IS found', () => {
    expect(
      hasHeatingCard({
        views: [{ sections: [{ cards: [{ type: 'custom:ga-heating-card' }] }] }],
      }),
    ).toBe(true);
  });
});

test.describe('resident-surface checks: the shapes they read', () => {
  test('cards are collected from views, sections and nested grids alike', () => {
    // The strategy builds room views as `sections`, so `views[].cards` is
    // legitimately empty — counting only that read a healthy dashboard as
    // empty once already (resident-ui.spec.ts, decision 1).
    const view = {
      cards: [{ type: 'a' }, { type: 'grid', cards: [{ type: 'b' }] }],
      sections: [{ cards: [{ type: 'c' }, { type: 'grid', cards: [{ type: 'd' }] }] }],
    };
    expect(allCards(view).map(c => c.type).sort()).toEqual(['a', 'b', 'c', 'd', 'grid', 'grid']);
  });

  test('the axis expectation is the one the card renders', () => {
    // Pinned here as well as in the card so that changing one without the
    // other is a red, not a silent drift across two repositories.
    expect([...AXIS_LABELS]).toEqual(['0', '6', '12', '18', '24']);
  });
});

// ───────────────────────────────────────────────────────────────────────────
// The card-registration judgements, proven red and green with no device.
//
// MEASURED, 2026-09-15, on a freshly flashed canary: every first-party card
// file served HTTP 200 with its `customElements.define` intact, and not one
// element registered. The fixtures below are that shape, plus the healthy
// shape, plus the two ways this check could quietly stop covering anything.
// ───────────────────────────────────────────────────────────────────────────

/** The module tags a healthy bundle puts on the page, cache-buster and all. */
const SHIPPED = ['ga-heating-card', 'ga-home-strategy', 'ga-master-card',
  'ga-sidebar-default', 'ga-thermostat-card'];

/**
 * What the device spec actually hands these judgements — three readings that
 * do NOT agree on shape, which is the whole reason `modulePath` exists.
 *
 * WHY NOT `<script type="module" src=...>`: Home Assistant does not emit that
 * for its extra modules. Its index template writes `import("<url>")` inside a
 * plain `<script>` with no `type` attribute (frontend
 * `src/html/index.html.template`), and its own app entries go the same way. A
 * first version of this check read module tags, found nothing on any device,
 * and could therefore report neither pass nor fail. These fixtures are what
 * make that shape impossible to reintroduce quietly.
 */
const MODULE_SRCS = [
  // 1. `performance` resource entries — ABSOLUTE, with the origin.
  'http://192.0.2.10:8123/frontend_latest/app.abc123.js',
  ...SHIPPED.map(
    id => `http://192.0.2.10:8123${FIRST_PARTY_URL_BASE}/${id}/${id}.js?v=1.11.0`),
  // 2. an `import("…")` call read out of an inline script — relative.
  `${FIRST_PARTY_URL_BASE}/ga-heating-card/ga-heating-card.js?v=1.11.0`,
  // 3. a vendored community card, served under the OTHER base path.
  'http://192.0.2.10:8123/ga_frontend_bundle_static/button-card/button-card.js?v=1.11.0',
];

/** Everything registered, as on a device where the loader works. */
const ALL_DEFINED: Record<string, boolean> = {
  'ga-heating-card': true,
  'ga-master-card': true,
  'ga-thermostat-card': true,
  'll-strategy-dashboard-ga-home': true,
};

/** Nothing registered — the canary, 2026-09-15. */
const NONE_DEFINED: Record<string, boolean> = {};

const HEALTHY_CUSTOM_CARDS = [
  { type: 'ga-heating-card', name: 'GA Heizplan' },
  { type: 'ga-master-card', name: 'GA Verwalten' },
  { type: 'ga-thermostat-card', name: 'GA Thermostat' },
];

test.describe('card registration: must-flag', () => {
  test('the 2026-09-15 shape — five assets shipped, nothing registered', () => {
    const assets = firstPartyAssetIds(MODULE_SRCS);
    expect(assets).toEqual(SHIPPED);
    expect(unregisteredAssets(assets, NONE_DEFINED)).toEqual([
      'ga-heating-card (ga-heating-card)',
      'ga-home-strategy (ll-strategy-dashboard-ga-home)',
      'ga-master-card (ga-master-card)',
      'ga-thermostat-card (ga-thermostat-card)',
    ]);
  });

  test('ONE card missing is named, not merely counted', () => {
    // A verdict of "3 of 4" sends somebody reading four files.
    const defined = { ...ALL_DEFINED, 'ga-heating-card': false };
    expect(unregisteredAssets(firstPartyAssetIds(MODULE_SRCS), defined)).toEqual([
      'ga-heating-card (ga-heating-card)',
    ]);
  });

  test('an empty window.customCards is flagged, by card type', () => {
    expect(missingAdvertisedCards([])).toEqual([...ADVERTISED_CARD_TYPES]);
  });

  test('a card that defines its element but never advertises is still flagged', () => {
    // Two independent readings: it renders where a dashboard already names it,
    // and it cannot be ADDED, because the card picker reads customCards.
    expect(
      missingAdvertisedCards(HEALTHY_CUSTOM_CARDS.filter(c => c.type !== 'ga-master-card')),
    ).toEqual(['ga-master-card']);
  });

  test("Home Assistant's own error message is read back, element by element", () => {
    expect(
      missingElementErrors([
        'Heizplan\nCustom element doesn\'t exist: ga-heating-card.',
        'Custom element doesn\'t exist: ga-thermostat-card.',
      ]),
    ).toEqual(['ga-heating-card', 'ga-thermostat-card']);
  });

  test('the same undefined element on four cards is ONE finding', () => {
    // Identical symptoms are one cause. Four lines here would read as four
    // separate defects and bury the second, different one.
    const four = Array(4).fill("Custom element doesn't exist: ga-thermostat-card.");
    expect(missingElementErrors(four)).toEqual(['ga-thermostat-card']);
  });

  test('a card added to the bundle that nobody mapped is a finding, not a skip', () => {
    // FAILS CLOSED. Without this, a new card would be silently dropped from
    // the comparison and the check would keep passing while covering less —
    // a guard rotting without ever going red.
    expect(unmappedAssets([...SHIPPED, 'ga-brand-new-card'])).toEqual(['ga-brand-new-card']);
  });
});

test.describe('card registration: must-NOT-flag', () => {
  test('a correctly wired bundle is clean on every one of these checks', () => {
    const assets = firstPartyAssetIds(MODULE_SRCS);
    expect(unregisteredAssets(assets, ALL_DEFINED)).toEqual([]);
    expect(unmappedAssets(assets)).toEqual([]);
    expect(missingAdvertisedCards(HEALTHY_CUSTOM_CARDS)).toEqual([]);
    expect(missingElementErrors(['Wohnzimmer 21 °C', 'Heizplan'])).toEqual([]);
  });

  test('ga-sidebar-default is not expected to define anything', () => {
    // It is a side-effect module that docks the drawer. Demanding an element
    // from it would be a permanent red on every healthy device.
    expect(EXPECTED_ELEMENTS['ga-sidebar-default']).toBeNull();
    expect(unregisteredAssets(['ga-sidebar-default'], NONE_DEFINED)).toEqual([]);
  });

  test('the strategy is expected under its OWN element name, not its asset name', () => {
    // `ga-home-strategy` defines `ll-strategy-dashboard-ga-home`. A check that
    // assumed the identity mapping would flag a perfectly healthy device.
    expect(EXPECTED_ELEMENTS['ga-home-strategy']).toBe('ll-strategy-dashboard-ga-home');
    expect(unregisteredAssets(['ga-home-strategy'], ALL_DEFINED)).toEqual([]);
    expect(unregisteredAssets(['ga-home-strategy'], { 'ga-home-strategy': true })).toEqual([
      'ga-home-strategy (ll-strategy-dashboard-ga-home)',
    ]);
  });

  test("Home Assistant's own app bundle is not one of our cards", () => {
    expect(firstPartyAssetIds(['/frontend_latest/app.abc123.js'])).toEqual([]);
  });

  test('an absolute URL and a relative one name the same asset once', () => {
    // `performance` gives absolute URLs, an inline `import()` gives relative
    // ones, and the device spec unions all of them. Without normalisation the
    // absolute form matches no prefix and every device reads as "nothing
    // injected" — which this check would then report as a failure.
    expect(modulePath('http://192.0.2.10:8123/a/b.js?v=1#x')).toBe('/a/b.js');
    expect(modulePath('/a/b.js?v=1')).toBe('/a/b.js');
    expect(firstPartyAssetIds([
      `http://h:8123${FIRST_PARTY_URL_BASE}/ga-master-card/x.js?v=1`,
      `${FIRST_PARTY_URL_BASE}/ga-master-card/x.js`,
    ])).toEqual(['ga-master-card']);
  });

  test('a vendored community card is not a first-party asset', () => {
    // Different base path, different lock, not this comparison's subject.
    // Counting it would put an id in the list that has no expected element and
    // turn every healthy device into an `unmappedAssets` finding.
    expect(
      firstPartyAssetIds(['/ga_frontend_bundle_static/button-card/button-card.js?v=1.11.0']),
    ).toEqual([]);
  });

  test('ordinary page text is not an error report', () => {
    expect(
      missingElementErrors(['Custom Dashboard', 'Element: Wohnzimmer', 'doesn\'t exist']),
    ).toEqual([]);
  });
});

test.describe('card registration: the shapes they read', () => {
  test('the cache-buster does not hide an asset id', () => {
    expect(firstPartyAssetIds([`${FIRST_PARTY_URL_BASE}/ga-master-card/x.js?v=1.11.0`]))
      .toEqual(['ga-master-card']);
  });

  test('the same asset injected twice is listed once', () => {
    expect(firstPartyAssetIds([
      `${FIRST_PARTY_URL_BASE}/ga-master-card/x.js?v=1.11.0`,
      `${FIRST_PARTY_URL_BASE}/ga-master-card/x.js?v=1.10.0`,
    ])).toEqual(['ga-master-card']);
  });

  test('the element list the device spec asks the browser about is derived, not typed', () => {
    // The device spec calls `customElements.get` on exactly these. Pinned so
    // that adding a card to EXPECTED_ELEMENTS cannot leave the browser probe
    // behind.
    expect(expectedElementNames(SHIPPED)).toEqual([
      'ga-heating-card',
      'ga-master-card',
      'ga-thermostat-card',
      'll-strategy-dashboard-ga-home',
    ]);
  });

  test('every advertised card type is one this file expects an element for', () => {
    // Two lists, one truth: a type in ADVERTISED_CARD_TYPES with no element
    // mapping would be demanded in the picker and never checked for existence.
    for (const t of ADVERTISED_CARD_TYPES) {
      expect(Object.values(EXPECTED_ELEMENTS)).toContain(t);
    }
  });
});
