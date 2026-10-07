/**
 * Fixtures for the heating-card judgements — must-flag and must-NOT-flag.
 *
 * `heating-cards.spec.ts` can only run against a real device. Its judgements
 * live in `helpers/heating-cards.ts` as functions over data, and this file runs
 * THAT module (never a copy) against inputs it must flag and inputs it must
 * not, with no device at all. A paste of a red run is evidence once; these are
 * evidence every time the helper changes.
 */
import { test, expect } from '@playwright/test';
import {
  SOURCE_REASON,
  boostDisplayProblems,
  boostRoomProblems,
  cardFailures,
  expectedLowCount,
  foreignBatteries,
  loggableEntries,
  maintenanceRowKind,
  maintenanceRowProblems,
  reasonMismatches,
  targetLine,
  versionAtLeast,
} from '../helpers/heating-cards';

const VALVE = 'climate.0x0cae5ffffe000001';
const OWN_BATTERY = 'sensor.0x0cae5ffffe000001_battery';
const SENSOR = 'sensor.0x449fdafffe000002_temperature';
const SENSOR_BATTERY = 'sensor.0x449fdafffe000002_battery';
const PHONE = 'sensor.some_phone_battery_level';
const NEIGHBOUR = 'sensor.0x0cae5ffffe000099_battery';

test.describe('heating-card checks: must-flag', () => {
  test('a resident change rendered as the system is flagged', () => {
    const p = reasonMismatches(
      [{ kind: 'target', source: 'resident' }],
      [{ when: 'Heute 19:00', what: 'Soll 20,0 → 21,0 °C', why: ' · System · Heizplan' }],
    );
    expect(p).toHaveLength(1);
  });

  test('a balancing change with no reason line is flagged (bundle < 1.23.0)', () => {
    expect(reasonMismatches(
      [{ kind: 'target', source: 'balancing' }],
      [{ when: '', what: 'Soll 20,0 → 30,0 °C', why: '' }],
    )).toHaveLength(1);
  });

  test('a source nobody pinned fails closed', () => {
    expect(reasonMismatches([{ kind: 'mode', source: 'telepathy' }], [{ when: '', what: 'KI → AUS', why: '' }]))
      .toHaveLength(1);
  });

  test('fewer lines than entries is flagged', () => {
    expect(reasonMismatches([{ kind: 'mode', source: 'plan' }, { kind: 'mode', source: 'plan' }],
      [{ when: '', what: 'KI → AUS', why: ' · System · Heizplan' }])).toHaveLength(1);
  });

  test('a phone in Wartung is flagged, wherever it sits', () => {
    const f = foreignBatteries([PHONE], [VALVE], [], 'kuche', { [PHONE]: { platform: 'mobile_app', area_id: 'kuche' } });
    expect(f).toHaveLength(1);
    expect(f[0]).toContain('phone');
  });

  test("another room's valve battery is flagged", () => {
    expect(foreignBatteries([NEIGHBOUR], [VALVE], [], 'kuche', {})).toHaveLength(1);
  });

  test('an own-looking battery registered in another area is flagged', () => {
    expect(foreignBatteries([OWN_BATTERY], [VALVE], [], 'kuche', { [OWN_BATTERY]: { platform: 'mqtt', area_id: 'bad' } }))
      .toHaveLength(1);
  });

  test('low readings are counted, the band edge included', () => {
    expect(expectedLowCount(['30', '19', '0'])).toBe(3);
  });

  test('the console lines a broken card leaves are flagged', () => {
    expect(cardFailures([
      "error: Custom element doesn't exist: ga-maintenance-card.",
      'warning: Konfigurationsfehler',
    ])).toHaveLength(2);
  });
});

test.describe('heating-card checks: must-NOT-flag', () => {
  test('every pinned source rendered with its own words passes', () => {
    const entries = Object.keys(SOURCE_REASON).map(source => ({ kind: 'mode', source }));
    const lines = Object.values(SOURCE_REASON).map(w => ({ when: '', what: 'KI → AUS', why: ` · ${w}` }));
    expect(reasonMismatches(entries, lines)).toEqual([]);
  });

  test("the room's own valve and thermometer batteries pass", () => {
    expect(foreignBatteries([OWN_BATTERY, SENSOR_BATTERY], [VALVE], [SENSOR], 'kuche', {
      [OWN_BATTERY]: { platform: 'mqtt', area_id: 'kuche' },
      [SENSOR_BATTERY]: { platform: 'mqtt', area_id: null },
    })).toEqual([]);
  });

  test('healthy, empty and non-numeric readings are not low', () => {
    expect(expectedLowCount(['31', '100', '', '   ', null, undefined, 'unavailable'])).toBe(0);
  });

  test('only mode and target changes are loggable', () => {
    expect(loggableEntries([{ kind: 'mode' }, { kind: 'target' }, { kind: 'other' }])).toHaveLength(2);
    expect(loggableEntries(undefined)).toEqual([]);
  });

  test('ordinary console lines are not card failures', () => {
    expect(cardFailures(['log: Lovelace loaded', 'warning: ResizeObserver loop limit exceeded'])).toEqual([]);
  });
});

test.describe('heating-card checks: the shapes they read', () => {
  test('a setpoint line is printed as the card prints it', () => {
    expect(targetLine(20, 21)).toBe('Soll 20,0 → 21,0 °C');
    expect(targetLine(null, 30)).toBe('Soll – → 30,0 °C');
  });

  test('version comparison', () => {
    expect(versionAtLeast('0.13.0', '0.13.0')).toBe(true);
    expect(versionAtLeast('0.12.9', '0.13.0')).toBe(false);
    expect(versionAtLeast('1.0', '0.13.0')).toBe(true);
  });
});

// ── Wartung rows by kind (bundle 1.23.2+) ──────────────────────────────────

/** The row measured on a correct card, rc8 (bench canary, 2026-10-07). */
const RADIO_ROW = { who: 'Thermostat 1', what: 'setzt eigenen Sollwert (2×)' };
const LOW_ROW = { who: 'Thermostat 2', what: 'Batterie niedrig' };
const FLAT_ROW = { who: 'Thermometer', what: 'Batterie fast leer' };

test.describe('Wartung rows: must-flag', () => {
  test('a low battery with no battery row is flagged, even when another row is there', () => {
    // The radio row must not stand in for the missing battery line.
    expect(maintenanceRowProblems(['25', '90'], [RADIO_ROW])).toHaveLength(1);
  });

  test('a battery row for a battery that is fine is flagged', () => {
    expect(maintenanceRowProblems(['90'], [LOW_ROW])).toHaveLength(1);
  });

  test('one battery row for two low batteries is flagged', () => {
    expect(maintenanceRowProblems(['25', '10'], [FLAT_ROW, RADIO_ROW])).toHaveLength(1);
  });

  test('a row of a kind nobody pinned fails closed', () => {
    const p = maintenanceRowProblems(['90'], [{ who: 'Ventil', what: 'Ventil klemmt' }]);
    expect(p).toHaveLength(1);
    expect(p[0]).toContain('unknown kind');
  });
});

test.describe('Wartung rows: must-NOT-flag', () => {
  test('a radio-health row beside healthy batteries is not a battery line (rc8)', () => {
    expect(maintenanceRowProblems(['100', '97'], [RADIO_ROW])).toEqual([]);
  });

  test('every kind the bundle renders is recognised', () => {
    expect(maintenanceRowKind('Batterie niedrig')).toBe('battery');
    expect(maintenanceRowKind('Batterie fast leer')).toBe('battery');
    expect(maintenanceRowKind('Funkverbindung schwach')).toBe('link');
    expect(maintenanceRowKind('Funkverbindung sehr schwach')).toBe('link');
    expect(maintenanceRowKind('antwortet verzögert (58 s)')).toBe('radiator');
    expect(maintenanceRowKind('setzt eigenen Sollwert')).toBe('radiator');
    expect(maintenanceRowKind('antwortet verzögert (31 s), setzt eigenen Sollwert (3×)')).toBe('radiator');
  });

  test('low batteries with their rows, plus radio rows, pass', () => {
    expect(maintenanceRowProblems(['25', '10', '80'], [
      FLAT_ROW, LOW_ROW, { who: 'Thermostat 3', what: 'Funkverbindung schwach' }, RADIO_ROW,
    ])).toEqual([]);
  });

  test('no rows and no low readings pass', () => {
    expect(maintenanceRowProblems(['100', '', null], [])).toEqual([]);
  });
});

// ── a running boost on the Profil card ─────────────────────────────────────

const boosted = (id: string, remaining_s: unknown, active = true) =>
  ({ entity_id: id, attributes: { override: { boost: { active, remaining_s } } } });

/** What the card showed on rc8 (bench canary, 2026-10-07) — correct. */
const RC8_STATUS = 'AKTIVBoost läuft — noch 4:58 in 3 Räumen';
const RC8_HINT = '(läuft in 3 Räumen · Ventile ganz offen)';

test.describe('boost: must-flag', () => {
  test('a room without an active boost is flagged', () => {
    expect(boostRoomProblems([boosted('climate.a', 290), boosted('climate.b', 0, false),
      { entity_id: 'climate.c', attributes: { override: null } }])).toHaveLength(2);
  });

  test('a boost longer than 5 minutes is flagged', () => {
    expect(boostRoomProblems([boosted('climate.a', 301)])).toHaveLength(1);
  });

  test('no rooms at all fails closed', () => {
    expect(boostRoomProblems([])).toHaveLength(1);
  });

  test('the idle card is flagged — no boost shown', () => {
    expect(boostDisplayProblems(3, 'Inaktiv — es gilt der Wochenplan.', '(Ventile kurzzeitig ganz öffnen)').length)
      .toBeGreaterThanOrEqual(3);
  });

  test('a wrong room count is flagged on both lines', () => {
    expect(boostDisplayProblems(3, 'AKTIVBoost läuft — noch 4:58 in 1 Raum', '(läuft in 1 Raum · Ventile ganz offen)'))
      .toHaveLength(2);
  });

  test('a countdown past 5:00 is flagged', () => {
    expect(boostDisplayProblems(3, 'AKTIVBoost läuft — noch 9:59 in 3 Räumen', RC8_HINT)).toHaveLength(1);
  });
});

test.describe('boost: must-NOT-flag', () => {
  test('every room boosted for at most 5 minutes passes', () => {
    expect(boostRoomProblems([boosted('climate.a', 300), boosted('climate.b', 1)])).toEqual([]);
  });

  test('the card as rc8 shows it passes — the hint need not repeat "Boost"', () => {
    expect(boostDisplayProblems(3, RC8_STATUS, RC8_HINT)).toEqual([]);
  });

  test('one room is "1 Raum", not "1 Räumen"', () => {
    expect(boostDisplayProblems(1, 'AKTIVBoost läuft — noch 0:42 in 1 Raum', '(läuft in 1 Raum · Ventile ganz offen)'))
      .toEqual([]);
  });
});
