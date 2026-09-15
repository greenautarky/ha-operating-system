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
  AXIS_LABELS,
  addressesInText,
  addressLikeLabels,
  allCards,
  hasHeatingCard,
  leakedStockPanels,
  missingExpectedPanels,
  personalDashboardsInSidebar,
  renderedLabels,
  sidebarPanels,
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
