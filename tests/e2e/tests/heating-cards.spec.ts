/**
 * The per-room heating cards a resident reads, through the real HA frontend —
 * ga-frontend-bundle 1.23.0 + ga_heating 0.13.0 (BOSv1.4.0-rc6).
 *
 *   1. "Aktivität"  ga-heating-log-card     — what changed in the room, and WHY
 *   2. "Wartung"    ga-maintenance-card     — which of the room's OWN sensors need a person
 *   3. Profil       ga-heating-actions-card — the balancing (ICHB) controls
 *   4. Room card    ga-thermostat-card      — "Beenden" on a running boost
 *   5. Every first-party card registers; the console never says it did not
 *
 * The bundle has unit tests for every one of these. They prove the card's code
 * against fixtures; they cannot prove that the strategy PLACES the card on a
 * real room, that ga_heating on the device publishes what the card reads, or
 * that a press reaches the radiators and comes back. That is what this file is.
 *
 * Every effect is read twice, separately: what the resident SEES (the card, in
 * the browser) and what the ROOM did (Core over REST, not the browser's `hass`
 * cache — if the websocket went stale, a test reading the same cache would be
 * wrong together with the card).
 *
 * UNDO IS PART OF EVERY TEST. A test that changes a room records the room's
 * mode, setpoint and manual clock first and restores them in `finally`, then
 * asserts the restore — a failing assertion must never leave a canary boosted,
 * balancing, or in MANUEL. A balancing run is started only on rooms that are in
 * KI with nothing overriding them: ga_heating 0.13.0 leaves a MANUEL room at
 * the run temperature after the run, which no undo here could take back without
 * restarting that room's manual clock.
 *
 * A balancing run already in progress (somebody else's) is never touched: the
 * run test skips and says so.
 *
 * The judgements and the pinned words live in `helpers/heating-cards.ts`;
 * `heating-cards-gate.spec.ts` proves them red and green with no device.
 *
 * Needs: DEVICE_URL (or DEVICE_IP) and credentials for haLogin(). Run it as the
 * resident by exporting HA_ADMIN_USER / HA_ADMIN_PASS for that account — the
 * variable names are the helper's, the account is whoever they name. Changes
 * made through the API are then made AS the resident, which is what the log's
 * "Benutzer" is about.
 */
import type { Page, TestInfo } from '@playwright/test';
import { test, expect } from '../fixtures/device';
import { haLogin } from '../helpers/auth';
import { waitForHA } from '../helpers/ha-api';
import {
  END_OVERRIDE,
  ICHB_CANCEL,
  ICHB_START,
  MAINTENANCE_QUIET,
  OVERRIDE_LABEL,
  SOURCE_REASON,
  cardFailures,
  expectedLowCount,
  foreignBatteries,
  loggableEntries,
  maintenanceRowProblems,
  reasonMismatches,
  reasonText,
  targetLine,
  type ChangeEntry,
  type EntityInfo,
  type MaintenanceRow,
  type RenderedLine,
} from '../helpers/heating-cards';

type State = { entity_id: string; state: string; attributes: Record<string, any> };
type Card = { type?: string; entity?: string; title?: string; batteries?: string[]; cards?: Card[] };
type View = { path?: string; title?: string; cards?: Card[]; sections?: { cards?: Card[] }[] };
type RoomView = { path: string; climate: string; cards: Card[] };

/** Elements the bundle's first-party modules define — PINNED, not read from the bundle. */
const FIRST_PARTY_ELEMENTS = [
  'ga-heating-card',
  'ga-thermostat-card',
  'ga-heating-actions-card',
  'ga-heating-log-card',
  'ga-maintenance-card',
  'ga-master-card',
  'll-strategy-dashboard-ga-home',
];

// ── REST, as the logged-in user ─────────────────────────────────────────────

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

async function stateOf(base: string, tok: string, id: string): Promise<State | undefined> {
  return (await states(base, tok)).find(s => s.entity_id === id);
}

/** Rooms are climate entities that carry `valves` — the cards' own discriminator. */
function rooms(all: State[]): State[] {
  return all
    .filter(s => s.entity_id.startsWith('climate.') && Array.isArray(s.attributes?.valves))
    .sort((a, b) => a.entity_id.localeCompare(b.entity_id));
}

async function callService(base: string, tok: string, domain: string, svc: string, data: object) {
  const r = await fetch(`${base}/api/services/${domain}/${svc}`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${tok}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
  });
  if (!r.ok) throw new Error(`${domain}.${svc} -> HTTP ${r.status}: ${(await r.text()).slice(0, 300)}`);
}

function ov(r: State | undefined, kind: string): any {
  return r?.attributes?.override?.[kind];
}
function anyIchb(all: State[]): string[] {
  return rooms(all).filter(r => ov(r, 'ichb')?.active === true).map(r => r.entity_id);
}

/** A room nothing is acting on: KI, no override, no manual clock. Safe to change and restore. */
function quiet(r: State): boolean {
  const o = r.attributes?.override;
  const overridden = o && typeof o === 'object' && Object.values(o).some((v: any) => v != null);
  return r.state === 'auto' && !overridden && !r.attributes?.manual_until;
}

interface Snapshot { id: string; state: string; temperature: number | null; manualUntil: string | null }
function snap(r: State): Snapshot {
  const t = r.attributes?.temperature;
  return {
    id: r.entity_id,
    state: r.state,
    temperature: typeof t === 'number' ? t : null,
    manualUntil: r.attributes?.manual_until ?? null,
  };
}

/** The room as the restore compares it. */
async function roomKey(base: string, tok: string, id: string): Promise<string> {
  const r = await stateOf(base, tok, id);
  if (!r) return 'gone';
  return JSON.stringify({
    state: r.state,
    temperature: r.attributes?.temperature ?? null,
    manual: r.attributes?.manual_until ?? null,
    boost: ov(r, 'boost') ?? null,
  });
}

/** How long a restored room must STAY restored before the restore counts. */
const RESTORE_HOLD_MS = 20_000;

/**
 * Put a KI room back and PROVE it: mode, setpoint, no manual clock, no override
 * left — and still so RESTORE_HOLD_MS later.
 *
 * The hold is paid for. On a bench canary on BOSv1.4.0-rc6 (2026-10-06) a room set back to KI one
 * second after a setpoint change read as restored on the first poll; one second
 * later ga_heating took the valve's late echo of the old setpoint for a hand on
 * the radiator ("valve") and put the room back in MANUEL for three hours. A
 * restore that checks once checks the race, not the room. Returns how many
 * attempts it took, so a caller can report a room that had to be put back twice.
 */
async function restoreQuietRoom(base: string, tok: string, before: Snapshot): Promise<number> {
  const want = JSON.stringify({ state: before.state, temperature: before.temperature, manual: before.manualUntil, boost: null });
  for (let attempt = 1; attempt <= 3; attempt++) {
    await callService(base, tok, 'ga_heating', 'cancel_boost', { entity_id: before.id }).catch(() => {});
    if ((await stateOf(base, tok, before.id))?.state !== before.state) {
      await callService(base, tok, 'climate', 'set_hvac_mode', { entity_id: before.id, hvac_mode: before.state });
    }
    await expect
      .poll(() => roomKey(base, tok, before.id),
        { timeout: 120_000, intervals: [2_000], message: `${before.id} was not restored to ${JSON.stringify(before)}` })
      .toBe(want);
    await new Promise(r => setTimeout(r, RESTORE_HOLD_MS));
    if ((await roomKey(base, tok, before.id)) === want) return attempt;
    console.log(`[restore] ${before.id} drifted after restore (attempt ${attempt}): ${await roomKey(base, tok, before.id)}`);
  }
  throw new Error(`${before.id} would not stay restored to ${want}: ${await roomKey(base, tok, before.id)}`);
}

/** Wait until every valve of the room reports this setpoint — its echo is then spent. */
async function valvesAt(base: string, tok: string, room: State, temp: number) {
  await expect
    .poll(async () => {
      const all = await states(base, tok);
      return (room.attributes.valves as string[])
        .filter(v => all.find(s => s.entity_id === v)?.attributes?.temperature !== temp);
    }, { timeout: 60_000, intervals: [2_000], message: `${room.entity_id}: valves never reported ${temp} °C` })
    .toEqual([]);
}

// ── the browser ─────────────────────────────────────────────────────────────

async function renderedConfig(page: Page): Promise<{ views?: View[] } | null> {
  return page.evaluate(`(() => {
    const deep = (root, out = []) => {
      for (const el of Array.from(root.querySelectorAll('*'))) {
        out.push(el);
        if (el.shadowRoot) deep(el.shadowRoot, out);
      }
      return out;
    };
    const panel = deep(document).find(e => e.tagName === 'HUI-ROOT' || e.tagName === 'HA-PANEL-LOVELACE');
    return (panel && panel.lovelace && panel.lovelace.config) || null;
  })()`) as Promise<{ views?: View[] } | null>;
}

/** Log in, open the resident's dashboard, wait for the strategy's generated config. */
async function openDashboard(page: Page, base: string): Promise<View[]> {
  await waitForHA(base);
  await haLogin(page, base);
  await page.goto(base, { waitUntil: 'domcontentloaded' });
  if (/greenautarky-setup/.test(page.url())) {
    test.skip(true, 'Device is still in the onboarding wizard — no resident, no room views. Complete onboarding, then re-run.');
  }
  await page.waitForURL(/lovelace|ga-home/, { timeout: 30_000 });
  let cfg = await renderedConfig(page);
  const deadline = Date.now() + 30_000;
  while (!cfg && Date.now() < deadline) {
    await page.waitForTimeout(500);
    cfg = await renderedConfig(page);
  }
  expect(cfg, 'No dashboard config: the frontend never connected (websocket through a proxy/tunnel?) — nothing below would mean anything.').not.toBeNull();
  return cfg?.views ?? [];
}

function cardsOf(v: View): Card[] {
  const flat = (cs: Card[]): Card[] => cs.flatMap(c => [c, ...flat(c.cards ?? [])]);
  return flat([...(v.cards ?? []), ...(v.sections ?? []).flatMap(s => s.cards ?? [])]);
}

/** Room views = views whose cards control a ga_heating room. */
function roomViews(views: View[], roomIds: string[]): RoomView[] {
  const out: RoomView[] = [];
  for (const v of views) {
    const cards = cardsOf(v);
    const climate = cards.map(c => c.entity).find(e => e && roomIds.includes(e));
    if (v.path && climate) out.push({ path: v.path, climate, cards });
  }
  return out;
}

/** The current dashboard's url_path (`lovelace` for the household dashboard). */
function dashboardPath(page: Page): string {
  const seg = new URL(page.url()).pathname.split('/').filter(Boolean);
  return seg[0] || 'lovelace';
}

async function openView(page: Page, base: string, dash: string, path: string) {
  await page.goto(`${base}/${dash}/${path}`, { waitUntil: 'domcontentloaded' });
}

/**
 * The shipped log card, mounted on the page with this room and `count` lines.
 *
 * The SAME element the bundle registered (customElements.get is what HA itself
 * uses for `custom:` types), configured to show every published entry, so the
 * reason words of the whole ring can be read — the view's card shows three.
 */
async function mountedLogLines(page: Page, entity: string, count: number): Promise<RenderedLine[]> {
  return page.evaluate(async ({ entity, count }) => {
    const Ctor = customElements.get('ga-heating-log-card') as any;
    if (!Ctor) throw new Error('ga-heating-log-card is not registered in this page');
    const old = document.getElementById('ga-e2e-log-probe');
    if (old) old.remove();
    const el = new Ctor();
    el.id = 'ga-e2e-log-probe';
    el.setConfig({ entity, count, title: 'probe' });
    document.body.appendChild(el);
    el.hass = (document.querySelector('home-assistant') as any).hass;
    await new Promise(r => setTimeout(r, 300));
    const lines = Array.from(el.querySelectorAll('li')).map((li: any) => {
      const why = (li.querySelector('.why')?.textContent || '').trim();
      const whatAll = (li.querySelector('.what')?.textContent || '').trim();
      return {
        when: (li.querySelector('.when')?.textContent || '').trim(),
        what: whatAll.replace(why, '').trim(),
        why,
      };
    });
    el.remove();
    return lines;
  }, { entity, count });
}

/** `hass.entities` reduced to what the Wartung judgement needs. */
async function entityInfo(page: Page, ids: string[]): Promise<Record<string, EntityInfo>> {
  return page.evaluate((ids: string[]) => {
    const hass = (document.querySelector('home-assistant') as any).hass;
    const out: Record<string, { platform?: string; area_id?: string | null }> = {};
    for (const id of ids) {
      const e = hass.entities?.[id];
      if (!e) { out[id] = {}; continue; }
      const dev = e.device_id ? hass.devices?.[e.device_id] : null;
      out[id] = { platform: e.platform, area_id: e.area_id || dev?.area_id || null };
    }
    return out;
  }, ids);
}

function note(info: TestInfo, type: string, description: string) {
  info.annotations.push({ type, description });
  console.log(`[${type}] ${description}`);
}

// ═══════════════════════════════════════════════════════════════════════════
// 1. Aktivität
// ═══════════════════════════════════════════════════════════════════════════

test.describe('Aktivität — ga-heating-log-card', () => {
  test('every room view carries the "Aktivität" card, rendered, not an error', async ({ page, deviceUrl }) => {
    const views = await openDashboard(page, deviceUrl);
    const tok = await token(page);
    const rv = roomViews(views, rooms(await states(deviceUrl, tok)).map(r => r.entity_id));
    test.skip(rv.length === 0, 'no ga_heating room on this device — no room view to read');

    // The CONFIG first: the strategy must place the card on every room.
    const missing = rv.filter(v => !v.cards.some(c => c.type === 'custom:ga-heating-log-card'));
    expect(
      missing.map(v => v.path),
      'Room views without a ga-heating-log-card in the generated dashboard. The strategy ' +
        'places it only with `change_log: true` in the dashboard config ' +
        '(ga-home-strategy default OFF); if this lists every room, the option is not set.',
    ).toEqual([]);

    // Then the BROWSER: rendered, titled, and reading something.
    const dash = dashboardPath(page);
    for (const v of rv) {
      await openView(page, deviceUrl, dash, v.path);
      const card = page.locator('ga-heating-log-card').first();
      await expect(card, `${v.path}: Aktivität not rendered`).toBeVisible({ timeout: 30_000 });
      await expect(card.locator('.hdr')).toHaveText('Aktivität');
      await expect(card, `${v.path}: the card could not read the room's history`).not.toContainText('Verlauf nicht verfügbar');
      await expect(card, `${v.path}: still loading after 30 s`).not.toContainText('Wird geladen', { timeout: 30_000 });
      expect(await page.locator('hui-error-card').count(), `${v.path}: an error card is on the view`).toBe(0);
    }
  });

  test('a setpoint change made by the resident appears as "Benutzer"', async ({ page, deviceUrl }, info) => {
    test.skip(info.project.name !== 'desktop', 'changes a real room — desktop only');
    await openDashboard(page, deviceUrl);
    const tok = await token(page);
    const target = rooms(await states(deviceUrl, tok)).find(quiet);
    test.skip(!target, 'no room in KI with nothing acting on it — refusing to change a room someone is using');
    const before = snap(target!);
    expect(before.temperature, `${before.id} has no setpoint to change`).not.toBeNull();
    const to = before.temperature! >= 29 ? before.temperature! - 1 : before.temperature! + 1;
    note(info, 'room', `${before.id}: ${before.state} ${before.temperature} °C → set ${to} °C`);

    const t0 = Date.now() - 5_000;
    let changed = false;
    try {
      await callService(deviceUrl, tok, 'climate', 'set_temperature', { entity_id: before.id, temperature: to });
      changed = true;

      // The ROOM: ga_heating published the change with its source.
      let entry: ChangeEntry | undefined;
      await expect
        .poll(async () => {
          const r = await stateOf(deviceUrl, tok, before.id);
          entry = loggableEntries(r?.attributes?.changes)
            .find(e => e.kind === 'target' && Number(e.to) === to && Date.parse(String(e.at)) >= t0);
          return entry ? String(entry.source) : 'none';
        }, { timeout: 30_000, message: `${before.id}: no change entry to ${to} °C was published` })
        .not.toBe('none');
      expect(entry!.source, `ga_heating attributed an API change by the logged-in user to "${entry!.source}"`).toBe('resident');

      // The CARD: the shipped element renders that entry with the resident's word.
      const r = await stateOf(deviceUrl, tok, before.id);
      const all = loggableEntries(r?.attributes?.changes);
      const lines = await mountedLogLines(page, before.id, all.length);
      const want = targetLine(entry!.from == null ? null : Number(entry!.from), to);
      const line = lines.find(l => l.what === want);
      expect(line, `no line "${want}" among:\n${lines.map(l => `${l.what} | ${l.why}`).join('\n')}`).toBeTruthy();
      expect(reasonText(line!.why)).toBe(SOURCE_REASON.resident);
    } finally {
      // Let the valves report the new setpoint before handing the room back:
      // their late echo is otherwise read as a hand on the radiator (see the
      // next test, and restoreQuietRoom).
      if (changed) await valvesAt(deviceUrl, tok, target!, to).catch(() => {});
      await restoreQuietRoom(deviceUrl, tok, before);
    }
  });

  test('a setpoint change taken back with KI at once stays taken back — the valve echo is not a hand', async ({ page, deviceUrl }, info) => {
    // MEASURED on a bench canary, BOSv1.4.0-rc6 (ga_heating 0.13.0), 2026-10-06: setpoint 17 → 18 as
    // the logged-in user, KI one second later. The room went to KI — and one
    // second after that ga_heating logged "valve: auto → heat, 17 → 18" and the
    // room sat in MANUEL at 18 °C with a three-hour clock nobody asked for. The
    // log blamed the resident's hand on the radiator.
    test.skip(info.project.name !== 'desktop', 'changes a real room — desktop only');
    await openDashboard(page, deviceUrl);
    const tok = await token(page);
    const target = rooms(await states(deviceUrl, tok)).find(quiet);
    test.skip(!target, 'no room in KI with nothing acting on it — refusing to change a room someone is using');
    const before = snap(target!);
    const to = before.temperature! >= 29 ? before.temperature! - 1 : before.temperature! + 1;
    note(info, 'room', `${before.id}: ${before.state} ${before.temperature} °C → ${to} °C → KI at once`);
    const t0 = Date.now() - 5_000;
    try {
      await callService(deviceUrl, tok, 'climate', 'set_temperature', { entity_id: before.id, temperature: to });
      await expect.poll(async () => (await stateOf(deviceUrl, tok, before.id))?.state, { timeout: 15_000 }).toBe('heat');
      await callService(deviceUrl, tok, 'climate', 'set_hvac_mode', { entity_id: before.id, hvac_mode: before.state });
      await new Promise(r => setTimeout(r, RESTORE_HOLD_MS));
      const r = await stateOf(deviceUrl, tok, before.id);
      const valveLines = loggableEntries(r?.attributes?.changes)
        .filter(e => e.source === 'valve' && Date.parse(String(e.at)) >= t0)
        .map(e => `${e.at} ${e.kind} ${e.from} → ${e.to}`);
      expect(valveLines, `${before.id}: nobody touched a radiator, yet the log says "valve"`).toEqual([]);
      expect(r?.state, `${before.id} fell back into MANUEL after KI`).toBe(before.state);
    } finally {
      await valvesAt(deviceUrl, tok, target!, before.temperature!).catch(() => {});
      const attempts = await restoreQuietRoom(deviceUrl, tok, before);
      if (attempts > 1) note(info, 'restore', `${before.id} needed ${attempts} restores`);
    }
  });

  test('every published change reads with the reason words for its source', async ({ page, deviceUrl }, info) => {
    await openDashboard(page, deviceUrl);
    const tok = await token(page);
    const rs = rooms(await states(deviceUrl, tok));
    test.skip(rs.length === 0, 'no ga_heating room on this device');

    let inspected = 0;
    const seen = new Set<string>();
    const problems: string[] = [];
    for (const r of rs) {
      const entries = loggableEntries(r.attributes?.changes);
      if (!entries.length) continue;
      const lines = await mountedLogLines(page, r.entity_id, entries.length);
      // Re-read: the ring may have moved between the two reads.
      const now = loggableEntries((await stateOf(deviceUrl, tok, r.entity_id))?.attributes?.changes);
      const basis = now.length === lines.length ? now : entries;
      problems.push(...reasonMismatches(basis, lines).map(p => `${r.entity_id} ${p}`));
      basis.forEach(e => seen.add(String(e.source)));
      inspected += lines.length;
    }
    note(info, 'sources seen', [...seen].sort().join(', ') || '(none)');
    expect(inspected, 'no room has a single published change — this test read nothing').toBeGreaterThan(0);
    expect(problems).toEqual([]);
  });

  test('a plan step reads "System · Heizplan"', async ({ page, deviceUrl }) => {
    await openDashboard(page, deviceUrl);
    const tok = await token(page);
    const withPlan = rooms(await states(deviceUrl, tok))
      .map(r => ({ id: r.entity_id, entries: loggableEntries(r.attributes?.changes) }))
      .filter(x => x.entries.some(e => e.source === 'plan'));
    // A plan step happens at a slot boundary; a test cannot make one without
    // rewriting the resident's plan. Where the ring holds none, say so — a skip
    // with a reason, never a pass over nothing.
    test.skip(withPlan.length === 0, 'no room has a plan step in its change ring right now');
    for (const { id, entries } of withPlan) {
      const lines = await mountedLogLines(page, id, entries.length);
      const idx = entries.findIndex(e => e.source === 'plan');
      expect(lines[idx], `${id}: line ${idx} not rendered`).toBeTruthy();
      expect(reasonText(lines[idx].why), `${id}: ${lines[idx].what}`).toBe(SOURCE_REASON.plan);
    }
  });
});

// ═══════════════════════════════════════════════════════════════════════════
// 2. Wartung
// ═══════════════════════════════════════════════════════════════════════════

test.describe('Wartung — ga-maintenance-card', () => {
  test("every room view says what its OWN sensors need, and never names a phone", async ({ page, deviceUrl }, info) => {
    const views = await openDashboard(page, deviceUrl);
    const tok = await token(page);
    const all = await states(deviceUrl, tok);
    const byId = new Map(all.map(s => [s.entity_id, s]));
    const rv = roomViews(views, rooms(all).map(r => r.entity_id));
    test.skip(rv.length === 0, 'no ga_heating room on this device — no room view to read');

    const dash = dashboardPath(page);
    let roomsChecked = 0;
    let batteriesChecked = 0;
    for (const v of rv) {
      const cfg = v.cards.find(c => c.type === 'custom:ga-maintenance-card');
      expect(cfg, `${v.path}: no ga-maintenance-card in the generated view`).toBeTruthy();
      const batteries = cfg!.batteries ?? [];
      const room = byId.get(v.climate)!;
      // The room's own thermometers / hygrometers: in this area by the registry.
      const climateSensors = all
        .filter(s => ['temperature', 'humidity'].includes(s.attributes?.device_class))
        .map(s => s.entity_id);
      const sensorInfo = await entityInfo(page, climateSensors);
      const sensors = climateSensors.filter(id => sensorInfo[id]?.area_id === v.path && sensorInfo[id]?.platform !== 'mobile_app');
      const foreign = foreignBatteries(
        batteries, room.attributes.valves, sensors, v.path, await entityInfo(page, batteries),
      );
      expect(foreign, `${v.path}: Wartung was given sensors that are not this room's`).toEqual([]);

      // Every phone battery on the device, wherever it sits, must be absent.
      const phones = Object.entries(await entityInfo(page, all.filter(s => s.attributes?.device_class === 'battery').map(s => s.entity_id)))
        .filter(([, i]) => i.platform === 'mobile_app').map(([id]) => id);
      expect(batteries.filter(b => phones.includes(b)), `${v.path}: a phone in Wartung`).toEqual([]);

      await openView(page, deviceUrl, dash, v.path);
      const card = page.locator('ga-maintenance-card').first();
      await expect(card, `${v.path}: Wartung not rendered`).toBeVisible({ timeout: 30_000 });
      await expect(card.locator('.hdr')).toHaveText('Wartung');
      // Rows are judged BY KIND. Since bundle 1.23.2 Wartung also lists radio
      // health ("Funkverbindung schwach", "setzt eigenen Sollwert (2×)"), so
      // counting every `li` as a low battery failed on a correct card (bench canary,
      // rc8, 2026-10-07). One battery row per low reading; no row of a kind
      // nobody pinned.
      const readings = batteries.map(b => byId.get(b)?.state);
      const low = expectedLowCount(readings);
      let rows: MaintenanceRow[] = [];
      await expect.poll(async () => {
        rows = await card.locator('li').evaluateAll(lis => lis.map(li => ({
          who: (li.querySelector('.who')?.textContent || '').trim(),
          what: (li.querySelector('.what')?.textContent || '').trim(),
        })));
        return maintenanceRowProblems(readings, rows);
      }, { timeout: 5_000, message: `${v.path}: Wartung rows do not match the readings` }).toEqual([]);
      if (rows.length === 0) await expect(card.locator('.quiet')).toHaveText(MAINTENANCE_QUIET);
      roomsChecked++;
      batteriesChecked += batteries.length;
    }
    note(info, 'coverage', `${roomsChecked} room(s), ${batteriesChecked} battery sensor(s)`);
    expect(roomsChecked).toBeGreaterThan(0);
    expect(batteriesChecked, 'no room handed Wartung a single battery — nothing was judged').toBeGreaterThan(0);
  });
});

// ═══════════════════════════════════════════════════════════════════════════
// 3. Balancing on the Profil card
// ═══════════════════════════════════════════════════════════════════════════

async function openProfil(page: Page, base: string) {
  await openDashboard(page, base);
  const dash = dashboardPath(page);
  await openView(page, base, dash, 'profil');
  const card = page.locator('ga-heating-actions-card');
  await card.waitFor({ state: 'visible', timeout: 45_000 });
  return { card, dash };
}

test.describe('Balancing — ga-heating-actions-card', () => {
  test('the balancing controls follow the ichb service, and are idle when nothing runs', async ({ page, deviceUrl }) => {
    const { card } = await openProfil(page, deviceUrl);
    const tok = await token(page);
    const running = anyIchb(await states(deviceUrl, tok));
    test.skip(running.length > 0, `a balancing run is in progress (${running.join(', ')}) — not idle, not ours`);
    const offered = await page.evaluate(() => Boolean((document.querySelector('home-assistant') as any).hass.services?.ga_heating?.ichb));
    const section = card.locator('.ichb-section');
    if (!offered) {
      // ga_heating < 0.13.0: no service, no button that would fail on every press.
      await expect(section).toBeHidden();
      return;
    }
    await expect(section).toBeVisible();
    await expect(card.locator('.ichb-start')).toHaveText(ICHB_START);
    await expect(card.locator('.ichb-start')).toBeEnabled();
    await expect(card.locator('.ichb-cancel'), 'the cancel button shows while idle').toBeHidden();
    await expect(card.locator('.ichbhint')).not.toContainText('läuft');
  });

  test('a run shows on the Profil card and in the rooms, cancels from the card, and logs "System · Einregulierung"', async ({ page, deviceUrl }, info) => {
    test.skip(info.project.name !== 'desktop', 'drives real valves — desktop only');
    test.setTimeout(420_000);
    const { card, dash } = await openProfil(page, deviceUrl);
    const tok = await token(page);
    const all = await states(deviceUrl, tok);
    const running = anyIchb(all);
    test.skip(running.length > 0, `a balancing run is already in progress (${running.join(', ')}) — not ours, not touched`);
    const offered = await page.evaluate(() => Boolean((document.querySelector('home-assistant') as any).hass.services?.ga_heating?.ichb));
    test.skip(!offered, 'ga_heating has no ichb service (< 0.13.0)');

    const chosen = rooms(all).filter(quiet);
    test.skip(chosen.length === 0, 'no room in KI with nothing acting on it — a MANUEL room would stay at the run temperature');
    const before = chosen.map(snap);
    const ceilings = new Map<string, string>();
    for (const r of chosen) for (const v of r.attributes.valves as string[]) {
      const n = `number.${v.replace(/^climate\./, '')}_valve_opening_degree`;
      const s = all.find(x => x.entity_id === n);
      if (s) ceilings.set(n, s.state);
    }
    note(info, 'run', `rooms ${before.map(b => b.id).join(', ')}; ceilings ${[...ceilings].map(([k, v]) => `${k}=${v}`).join(', ')}`);
    const ids = before.map(b => b.id);

    try {
      // Started through the SERVICE, five minutes, only the quiet rooms.
      await callService(deviceUrl, tok, 'ga_heating', 'ichb', { minutes: 5, rooms: ids });
      await expect
        .poll(async () => anyIchb(await states(deviceUrl, tok)).sort().join(','), { timeout: 60_000, message: 'the run never became active in the chosen rooms' })
        .toBe([...ids].sort().join(','));

      // Profil card: running, cancel offered, no second start.
      await expect(card.locator('.ichbhint')).toContainText('läuft', { timeout: 30_000 });
      await expect(card.locator('.ichb-cancel')).toBeVisible();
      await expect(card.locator('.ichb-cancel')).toHaveText(ICHB_CANCEL);
      await expect(card.locator('.ichb-start')).toBeDisabled();

      // Each room's own card names the run — and offers NO Beenden for it.
      for (const id of ids) {
        const v = roomViews((await renderedConfig(page))?.views ?? [], [id])[0];
        if (!v) { note(info, 'room view', `${id}: no view in the dashboard`); continue; }
        await openView(page, deviceUrl, dash, v.path);
        const row = page.locator('ga-thermostat-card .manualrow').first();
        await expect(row, `${id}: room card does not say the run is going`).toContainText(OVERRIDE_LABEL.ichb, { timeout: 30_000 });
        await expect(row.locator('.endov'), `${id}: a per-room Beenden on a whole-flat run`).toHaveCount(0);
      }

      // Cancel FROM THE CARD.
      await openView(page, deviceUrl, dash, 'profil');
      const card2 = page.locator('ga-heating-actions-card');
      await card2.locator('.ichb-cancel').click();
      await expect
        .poll(async () => anyIchb(await states(deviceUrl, tok)).length, { timeout: 60_000, message: 'Abgleich abbrechen left the run going' })
        .toBe(0);
      await expect(card2.locator('.ichb-cancel')).toBeHidden({ timeout: 30_000 });
      await expect(card2.locator('.ichb-start')).toBeEnabled();
      await expect(card2.locator('.ichbhint')).not.toContainText('läuft');

      // The log names the run.
      for (const id of ids) {
        const entries = loggableEntries((await stateOf(deviceUrl, tok, id))?.attributes?.changes);
        const idx = entries.findIndex(e => e.source === 'balancing');
        expect(idx, `${id}: no change with source "balancing" was published for the run`).toBeGreaterThanOrEqual(0);
        const lines = await mountedLogLines(page, id, entries.length);
        expect(reasonText(lines[idx]?.why ?? ''), `${id}: ${lines[idx]?.what}`).toBe(SOURCE_REASON.balancing);
      }
    } finally {
      await callService(deviceUrl, tok, 'ga_heating', 'cancel_ichb', {}).catch(() => {});
      await expect
        .poll(async () => {
          const now = await states(deviceUrl, tok);
          return [...ceilings].filter(([n, v]) => now.find(s => s.entity_id === n)?.state !== v).map(([n]) => n);
        }, { timeout: 120_000, intervals: [3_000], message: 'valve ceilings were not given back' })
        .toEqual([]);
      for (const b of before) await restoreQuietRoom(deviceUrl, tok, b);
    }
  });
});

// ═══════════════════════════════════════════════════════════════════════════
// 4. Beenden on a running boost
// ═══════════════════════════════════════════════════════════════════════════

test.describe('Boost — Beenden in the room card', () => {
  test('"Beenden" ends a running boost and the room is back where it was — no MANUEL left', async ({ page, deviceUrl }, info) => {
    test.skip(info.project.name !== 'desktop', 'drives a real valve — desktop only');
    const views = await openDashboard(page, deviceUrl);
    const tok = await token(page);
    const all = await states(deviceUrl, tok);
    const target = rooms(all).find(quiet);
    test.skip(!target, 'no room in KI with nothing acting on it');
    const before = snap(target!);
    const v = roomViews(views, [before.id])[0];
    expect(v, `${before.id} has no room view`).toBeTruthy();
    note(info, 'room', `${before.id} (${v.path}): ${before.state} ${before.temperature} °C`);

    try {
      await callService(deviceUrl, tok, 'ga_heating', 'boost', { entity_id: before.id, minutes: 5 });
      await expect
        .poll(async () => ov(await stateOf(deviceUrl, tok, before.id), 'boost')?.active === true, { timeout: 30_000 })
        .toBe(true);

      await openView(page, deviceUrl, dashboardPath(page), v.path);
      const row = page.locator('ga-thermostat-card .manualrow').first();
      await expect(row).toContainText(OVERRIDE_LABEL.boost, { timeout: 30_000 });
      const end = row.locator('.endov');
      await expect(end).toHaveText(END_OVERRIDE);
      await end.click();

      // The ROOM: boost gone, the stored decision back — KI, the plan's
      // setpoint, no manual clock. Pressing KI instead would also clear the
      // boost; what this proves is that nothing ELSE was written.
      await expect
        .poll(async () => {
          const r = await stateOf(deviceUrl, tok, before.id);
          return JSON.stringify({ boost: ov(r, 'boost') ?? null, state: r?.state, manual: r?.attributes?.manual_until ?? null });
        }, { timeout: 60_000, message: 'Beenden did not hand the room back' })
        .toBe(JSON.stringify({ boost: null, state: before.state, manual: before.manualUntil }));
      await expect
        .poll(async () => (await stateOf(deviceUrl, tok, before.id))?.attributes?.temperature ?? null, { timeout: 90_000 })
        .toBe(before.temperature);
      // And STILL so a little later: a valve's late echo of the boost setpoint
      // must not be read as a hand on the radiator and bring MANUEL back.
      await new Promise(r => setTimeout(r, RESTORE_HOLD_MS));
      const after = await stateOf(deviceUrl, tok, before.id);
      expect({ state: after?.state, manual: after?.attributes?.manual_until ?? null },
        `${before.id} did not stay where Beenden put it`).toEqual({ state: before.state, manual: before.manualUntil });
      // The CARD: the row is gone with the boost.
      await expect(page.locator('ga-thermostat-card .endov')).toHaveCount(0, { timeout: 30_000 });
    } finally {
      await restoreQuietRoom(deviceUrl, tok, before);
    }
  });
});

// ═══════════════════════════════════════════════════════════════════════════
// 5. Registration and the console
// ═══════════════════════════════════════════════════════════════════════════

test.describe('First-party cards — registered, and the console agrees', () => {
  test('every first-party element is defined and no view logs a card failure', async ({ page, deviceUrl }, info) => {
    const consoleLines: string[] = [];
    page.on('console', m => consoleLines.push(`${m.type()}: ${m.text()}`));
    page.on('pageerror', e => consoleLines.push(`pageerror: ${e.message}`));

    const views = await openDashboard(page, deviceUrl);
    const defined = await page.evaluate((ns: string[]) => Object.fromEntries(ns.map(n => [n, !!customElements.get(n)])), FIRST_PARTY_ELEMENTS);
    expect(Object.entries(defined).filter(([, d]) => !d).map(([n]) => n), 'first-party elements never defined').toEqual([]);

    // Walk every view the resident has, so every card the strategy places is built.
    const dash = dashboardPath(page);
    let gaCards = 0;
    const errorCards: string[] = [];
    for (const v of views) {
      if (!v.path) continue;
      await openView(page, deviceUrl, dash, v.path);
      await page.waitForTimeout(2_500);
      const n = await page.evaluate((ns: string[]) => {
        const deep = (root: ParentNode, out: Element[] = []): Element[] => {
          for (const el of Array.from(root.querySelectorAll('*'))) {
            out.push(el);
            if ((el as any).shadowRoot) deep((el as any).shadowRoot, out);
          }
          return out;
        };
        const els = deep(document);
        return {
          ga: els.filter(e => ns.includes(e.tagName.toLowerCase())).length,
          errors: els.filter(e => e.tagName === 'HUI-ERROR-CARD').map(e => (e.textContent || '').trim().slice(0, 200)),
        };
      }, FIRST_PARTY_ELEMENTS);
      gaCards += n.ga;
      errorCards.push(...n.errors.map(t => `${v.path}: ${t}`));
    }
    note(info, 'coverage', `${views.length} view(s), ${gaCards} first-party card element(s), ${consoleLines.length} console line(s)`);
    expect(gaCards, 'no first-party card was rendered on any view — nothing was inspected').toBeGreaterThan(0);
    expect(errorCards, 'error cards on the resident dashboard').toEqual([]);
    expect(cardFailures(consoleLines), 'the console reports a card that did not render').toEqual([]);
  });
});
