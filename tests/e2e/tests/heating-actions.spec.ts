/**
 * Heating actions card — what a resident can DO to the whole flat, and what
 * each button actually does to the rooms.
 *
 * The card (ga-frontend-bundle, `ga-heating-actions-card`) sits on the Profil
 * view. Every button calls something ga_heating already owns, so every test
 * here asserts two things separately:
 *
 *   1. what the resident SEES — the message, the status line, the frost text;
 *   2. what the ROOMS did — read from Core over REST, not from the browser's
 *      `hass` object. The card reads that object too; if its websocket went
 *      stale, a test that read the same cache would be wrong together with it.
 *
 * Every test starts from, and must return to, the same baseline: every room in
 * `auto` with no override in force. The baseline is asserted before the first
 * test (a suite run on a dirty flat proves nothing — it cannot tell its own
 * effect from the one already there) and restored + re-asserted after EACH
 * test through the API, so a failing assertion can never leave a canary
 * boosted, off, or on holiday.
 *
 * Effects run on the desktop project only: they drive real valves, and three
 * viewports would triple every boost for no extra information. The layout
 * test runs on all three.
 *
 * Needs: DEVICE_URL (or DEVICE_IP) and credentials for haLogin(). Run it as the
 * resident by exporting HA_ADMIN_USER / HA_ADMIN_PASS for that account — the
 * variable names are the helper's, the account is whoever they name.
 */
import type { Page } from '@playwright/test';
import { test, expect } from '../fixtures/device';
import { haLogin } from '../helpers/auth';

type State = { entity_id: string; state: string; attributes: Record<string, any> };

const SICK_MAX_HOURS = 48; // mirrors the card; a change there must fail here
const TMIN = 5;
const TMAX = 30;

async function token(page: Page): Promise<string> {
  const t = await page.evaluate(() => {
    try { return JSON.parse(localStorage.getItem('hassTokens') || '{}').access_token || ''; }
    catch { return ''; }
  });
  if (!t) throw new Error('no access token in localStorage after haLogin');
  return t;
}

async function states(base: string, tok: string): Promise<State[]> {
  const r = await fetch(`${base}/api/states`, { headers: { Authorization: `Bearer ${tok}` } });
  if (!r.ok) throw new Error(`GET /api/states -> ${r.status}`);
  return (await r.json()) as State[];
}

/** Rooms are climate entities that carry `valves` — the card's own discriminator. */
function rooms(all: State[]): State[] {
  return all
    .filter(s => s.entity_id.startsWith('climate.') && Array.isArray(s.attributes?.valves))
    .sort((a, b) => a.entity_id.localeCompare(b.entity_id));
}

function frostValues(all: State[]): number[] {
  const v = all
    .filter(s => s.entity_id.startsWith('number.') && s.entity_id.endsWith('_frost_protection_temperature'))
    .map(s => Number(s.state))
    .filter(n => Number.isFinite(n));
  return Array.from(new Set(v)).sort((a, b) => a - b);
}

function active(r: State, kind: 'boost' | 'absence'): boolean {
  return !!r.attributes?.override?.[kind]?.active;
}
function present(r: State, kind: 'boost' | 'absence'): boolean {
  return r.attributes?.override?.[kind] != null;
}

/** One line per room, for failure messages that say WHICH room. */
function describe(rs: State[]): string {
  return rs.map(r => `${r.entity_id}=${r.state} override=${JSON.stringify(r.attributes?.override)}`).join('\n');
}

async function callService(base: string, tok: string, domain: string, svc: string, data: object) {
  const r = await fetch(`${base}/api/services/${domain}/${svc}`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${tok}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
  });
  return r.status;
}

/** Undo everything the card can do, through the API, and wait for Core to agree. */
async function restoreBaseline(base: string, tok: string) {
  for (const r of rooms(await states(base, tok))) {
    await callService(base, tok, 'ga_heating', 'cancel_boost', { entity_id: r.entity_id });
    await fetch(`${base}/api/ga_heating/absence`, {
      method: 'DELETE',
      headers: { Authorization: `Bearer ${tok}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ entity_id: r.entity_id }),
    });
    await callService(base, tok, 'climate', 'set_hvac_mode', { entity_id: r.entity_id, hvac_mode: 'auto' });
  }
  await expect
    .poll(async () => {
      const rs = rooms(await states(base, tok));
      return rs.every(r => r.state === 'auto' && !present(r, 'boost') && !present(r, 'absence'));
    }, { timeout: 30_000, message: 'baseline (all rooms auto, no override) not restored' })
    .toBe(true);
}

async function openProfil(page: Page, base: string) {
  await haLogin(page, base);
  await page.goto(`${base}/lovelace/profil`, { waitUntil: 'domcontentloaded' });
  const card = page.locator('ga-heating-actions-card');
  await card.waitFor({ state: 'visible', timeout: 45_000 });
  return card;
}

async function openForm(card: ReturnType<Page['locator']>) {
  if (!(await card.locator('.form .fields').isVisible().catch(() => false))) {
    await card.locator('.toggle-form').click();
  }
  await expect(card.locator('.kinds')).toBeVisible();
}

function isoDay(offsetDays: number): string {
  const d = new Date(Date.now() + offsetDays * 86_400_000);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

test.describe('Heating actions card — layout', () => {
  test('the card renders its three quick actions and the Sonderplan section', async ({ page, deviceUrl }) => {
    const card = await openProfil(page, deviceUrl);
    await expect(card.locator('.boost')).toHaveText('Boost setzen');
    await expect(card.locator('.planall')).toHaveText('Alle → KI');
    await expect(card.locator('.offall')).toHaveText('Alle AUS');
    await expect(card.locator('.sph')).toContainText('Sonderpläne');
    // No horizontal scroll: the card sits in a panel view and must fit a phone.
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    expect(overflow, 'the Profil view scrolls sideways').toBeLessThanOrEqual(1);
  });
});

test.describe('Heating actions card — effects on the rooms', () => {
  test.describe.configure({ mode: 'serial' });
  let tok = '';

  test.beforeEach(async ({ page, deviceUrl }, info) => {
    test.skip(info.project.name !== 'desktop', 'drives real valves — desktop only');
    const card = await openProfil(page, deviceUrl);
    tok = await token(page);
    const rs = rooms(await states(deviceUrl, tok));
    expect(rs.length, 'no ga_heating room on this device — nothing to act on').toBeGreaterThan(0);
    // A dirty flat makes every assertion below ambiguous. Refuse, do not clean silently.
    const dirty = rs.filter(r => r.state !== 'auto' || present(r, 'boost') || present(r, 'absence'));
    expect(dirty.map(r => r.entity_id), `baseline is not clean:\n${describe(dirty)}`).toEqual([]);
    await expect(card.locator('.status')).toContainText('Inaktiv');
  });

  test.afterEach(async ({ deviceUrl }, info) => {
    if (info.project.name !== 'desktop' || !tok) return;
    await restoreBaseline(deviceUrl, tok);
  });

  test('Boost setzen boosts EVERY room for at most 5 minutes, and Alle → KI ends it', async ({ page, deviceUrl }) => {
    const card = page.locator('ga-heating-actions-card');
    await card.locator('.boost').click();
    await expect
      .poll(async () => rooms(await states(deviceUrl, tok)).filter(r => active(r, 'boost')).length,
        { timeout: 30_000, message: 'not every room reports an active boost' })
      .toBe(rooms(await states(deviceUrl, tok)).length);
    for (const r of rooms(await states(deviceUrl, tok))) {
      const rem = Number(r.attributes.override.boost.remaining_s);
      expect(rem, `${r.entity_id} remaining_s`).toBeGreaterThan(0);
      expect(rem, `${r.entity_id} boosts longer than the card's 5 minutes`).toBeLessThanOrEqual(300);
    }
    // The resident sees that a boost is running, without opening anything.
    // Two elements say it, and both must: the status line (what is running,
    // and for how long) and the hint (how many rooms, and that the valves are
    // wide open). One combined locator matched both and failed in strict mode
    // on a canary on 2026-09-24 while the card was showing exactly the right thing.
    await expect(card.locator('.status')).toContainText(/Boost/i);
    await expect(card.locator('.boosthint')).toContainText(/Boost/i);

    await card.locator('.planall').click();
    await expect
      .poll(async () => rooms(await states(deviceUrl, tok)).some(r => active(r, 'boost')),
        { timeout: 30_000, message: 'Alle → KI left a boost running' })
      .toBe(false);
    expect(rooms(await states(deviceUrl, tok)).every(r => r.state === 'auto')).toBe(true);
  });

  test('Alle AUS turns every room off and names the frost protection the VALVES hold', async ({ page, deviceUrl }) => {
    const card = page.locator('ga-heating-actions-card');
    const expected = frostValues(await states(deviceUrl, tok));
    await card.locator('.offall').click();
    await expect
      .poll(async () => rooms(await states(deviceUrl, tok)).every(r => r.state === 'off'),
        { timeout: 30_000, message: 'not every room went off' })
      .toBe(true);
    if (expected.length) {
      // The number is read from the valves, never assumed: a hardcoded 5 °C
      // would state a value this flat does not use.
      await expect(card.locator('.frosthint')).toContainText(`${expected.join(' / ')} °C`);
    } else {
      await expect(card.locator('.frosthint')).toHaveText('');
    }
    await card.locator('.planall').click();
    await expect
      .poll(async () => rooms(await states(deviceUrl, tok)).every(r => r.state === 'auto'),
        { timeout: 30_000, message: 'Alle → KI did not bring the rooms back to auto' })
      .toBe(true);
  });

  test('Alle → KI on a quiet flat changes nothing', async ({ page, deviceUrl }) => {
    const before = rooms(await states(deviceUrl, tok)).map(r => r.entity_id + ':' + r.state);
    await page.locator('ga-heating-actions-card .planall').click();
    await page.waitForTimeout(3000);
    const after = rooms(await states(deviceUrl, tok));
    expect(after.map(r => r.entity_id + ':' + r.state)).toEqual(before);
    expect(after.some(r => present(r, 'boost') || present(r, 'absence'))).toBe(false);
  });

  test('Krankheit: 6 h at 21 °C starts NOW in every room and is visible without opening the form', async ({ page, deviceUrl }) => {
    const card = page.locator('ga-heating-actions-card');
    await openForm(card);
    await card.locator('.kind[data-kind="sick"]').click();
    await expect(card.locator('input.off'), 'sickness must not offer "Heizung aus"').toHaveCount(0);
    await card.locator('input.hours').fill('6');
    await card.locator('input.temp').fill('21');
    const t0 = Date.now();
    await card.locator('.apply').click();
    await expect
      .poll(async () => rooms(await states(deviceUrl, tok)).every(r => active(r, 'absence')),
        { timeout: 30_000, message: 'not every room reports the sickness plan as active' })
      .toBe(true);
    for (const r of rooms(await states(deviceUrl, tok))) {
      const a = r.attributes.override.absence;
      expect(Number(a.temp), `${r.entity_id} temp`).toBe(21);
      expect(!!a.off, `${r.entity_id} off`).toBe(false);
      const hours = (Date.parse(a.end) - Date.parse(a.start)) / 3_600_000;
      expect(hours, `${r.entity_id} duration`).toBeCloseTo(6, 1);
      expect(Math.abs(Date.parse(a.start) - t0), `${r.entity_id} did not start now`).toBeLessThan(5 * 60_000);
    }
    // Status is always visible; collapse the form and it must still say so.
    await card.locator('.toggle-form').click();
    await expect(card.locator('.status')).not.toContainText('Inaktiv');

    await openForm(card);
    await card.locator('.cancel-absence').click();
    await expect
      .poll(async () => rooms(await states(deviceUrl, tok)).some(r => present(r, 'absence')),
        { timeout: 30_000, message: 'Deaktivieren left a Sonderplan in force' })
      .toBe(false);
    await expect(card.locator('.status')).toContainText('Inaktiv');
  });

  for (const [hours, why] of [['0', 'zero hours'], [String(SICK_MAX_HOURS + 1), 'past the 48 h limit']] as const) {
    test(`Krankheit refuses ${why} before sending anything`, async ({ page, deviceUrl }) => {
      const card = page.locator('ga-heating-actions-card');
      await openForm(card);
      await card.locator('.kind[data-kind="sick"]').click();
      await card.locator('input.hours').fill(hours);
      await card.locator('input.temp').fill('21');
      await card.locator('.apply').click();
      await expect(card.locator('.msg')).toContainText(`zwischen 1 und ${SICK_MAX_HOURS} Stunden`);
      await page.waitForTimeout(2000);
      expect(rooms(await states(deviceUrl, tok)).some(r => present(r, 'absence'))).toBe(false);
    });
  }

  for (const t of [String(TMIN - 1), String(TMAX + 1)]) {
    test(`Krankheit refuses ${t} °C before sending anything`, async ({ page, deviceUrl }) => {
      const card = page.locator('ga-heating-actions-card');
      await openForm(card);
      await card.locator('.kind[data-kind="sick"]').click();
      await card.locator('input.hours').fill('6');
      await card.locator('input.temp').fill(t);
      await card.locator('.apply').click();
      await expect(card.locator('.msg')).toContainText(`zwischen ${TMIN} und ${TMAX} °C`);
      await page.waitForTimeout(2000);
      expect(rooms(await states(deviceUrl, tok)).some(r => present(r, 'absence'))).toBe(false);
    });
  }

  test('Urlaub in the future at 16 °C is SCHEDULED, not yet active, with the end time the resident chose', async ({ page, deviceUrl }) => {
    const card = page.locator('ga-heating-actions-card');
    await openForm(card);
    await card.locator('.kind[data-kind="holiday"]').click();
    await card.locator('input.start').fill(isoDay(2));
    await card.locator('select.starttime').selectOption('08:00');
    await card.locator('input.end').fill(isoDay(4));
    await card.locator('select.endtime').selectOption('15:30');
    await card.locator('input.temp').fill('16');
    await card.locator('.apply').click();
    await expect
      .poll(async () => rooms(await states(deviceUrl, tok)).every(r => present(r, 'absence')),
        { timeout: 30_000, message: 'not every room carries the holiday' })
      .toBe(true);
    for (const r of rooms(await states(deviceUrl, tok))) {
      const a = r.attributes.override.absence;
      expect(a.active, `${r.entity_id}: a holiday two days away must not be in force yet`).toBe(false);
      expect(String(a.start)).toContain(`${isoDay(2)}T08:00`);
      expect(String(a.end), 'the END carries a time — ending at midnight means coming home to a cold flat').toContain(`${isoDay(4)}T15:30`);
      expect(Number(a.temp)).toBe(16);
    }
    await card.locator('.cancel-absence').click();
    await expect
      .poll(async () => rooms(await states(deviceUrl, tok)).some(r => present(r, 'absence')), { timeout: 30_000 })
      .toBe(false);
  });

  test('Urlaub with "Heizung aus" switches off instead of sending a temperature', async ({ page, deviceUrl }) => {
    const card = page.locator('ga-heating-actions-card');
    await openForm(card);
    await card.locator('.kind[data-kind="holiday"]').click();
    await card.locator('input.start').fill(isoDay(2));
    await card.locator('input.end').fill(isoDay(3));
    await card.locator('input.off').check();
    await card.locator('.apply').click();
    await expect
      .poll(async () => rooms(await states(deviceUrl, tok)).every(r => r.attributes?.override?.absence?.off === true),
        { timeout: 30_000, message: 'not every room carries the off-holiday' })
      .toBe(true);
    await card.locator('.cancel-absence').click();
    await expect
      .poll(async () => rooms(await states(deviceUrl, tok)).some(r => present(r, 'absence')), { timeout: 30_000 })
      .toBe(false);
  });

  test('Urlaub refuses an end before its start before sending anything', async ({ page, deviceUrl }) => {
    const card = page.locator('ga-heating-actions-card');
    await openForm(card);
    await card.locator('.kind[data-kind="holiday"]').click();
    await card.locator('input.start').fill(isoDay(4));
    await card.locator('input.end').fill(isoDay(2));
    await card.locator('input.temp').fill('16');
    await card.locator('.apply').click();
    await expect(card.locator('.msg')).toContainText('Das Ende liegt vor dem Anfang');
    await page.waitForTimeout(2000);
    expect(rooms(await states(deviceUrl, tok)).some(r => present(r, 'absence'))).toBe(false);
  });

  test('Urlaub refuses a missing date before sending anything', async ({ page, deviceUrl }) => {
    const card = page.locator('ga-heating-actions-card');
    await openForm(card);
    await card.locator('.kind[data-kind="holiday"]').click();
    await card.locator('input.start').fill(isoDay(2));
    await card.locator('input.temp').fill('16');
    await card.locator('.apply').click();
    await expect(card.locator('.msg')).toContainText('Bitte Anfang und Ende angeben');
    await page.waitForTimeout(2000);
    expect(rooms(await states(deviceUrl, tok)).some(r => present(r, 'absence'))).toBe(false);
  });

  test('a Sonderplan for ONE room leaves the other rooms alone', async ({ page, deviceUrl }) => {
    const card = page.locator('ga-heating-actions-card');
    const all = rooms(await states(deviceUrl, tok));
    test.skip(all.length < 2, 'needs at least two rooms to tell "one" from "all"');
    const target = all[0].entity_id;
    await openForm(card);
    await card.locator('.kind[data-kind="sick"]').click();
    await card.locator('input.allrooms').uncheck();
    const toggle = card.locator('.toggle-rooms');
    if (await toggle.isVisible().catch(() => false)) await toggle.click();
    await card.locator(`input[type="checkbox"][data-id="${target}"]`).check();
    await card.locator('input.hours').fill('2');
    await card.locator('input.temp').fill('21');
    await card.locator('.apply').click();
    await expect
      .poll(async () => rooms(await states(deviceUrl, tok)).filter(r => present(r, 'absence')).map(r => r.entity_id),
        { timeout: 30_000, message: 'the Sonderplan did not land on exactly the one room chosen' })
      .toEqual([target]);
    await card.locator('.cancel-absence').click();
    await expect
      .poll(async () => rooms(await states(deviceUrl, tok)).some(r => present(r, 'absence')), { timeout: 30_000 })
      .toBe(false);
  });
});
