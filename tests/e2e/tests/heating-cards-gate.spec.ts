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
  cardFailures,
  expectedLowCount,
  foreignBatteries,
  loggableEntries,
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
