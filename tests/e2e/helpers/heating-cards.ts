/**
 * The judgements `heating-cards.spec.ts` makes about the per-room heating cards
 * a resident reads — "Aktivität" (`ga-heating-log-card`), "Wartung"
 * (`ga-maintenance-card`), the room's override row in `ga-thermostat-card` and
 * the balancing controls on the Profil card (`ga-heating-actions-card`).
 *
 * Kept apart from the browser plumbing for the same reason as
 * `resident-surface.ts`: a judgement that only a device can run can only be
 * proven by a device. As functions over data, `heating-cards-gate.spec.ts` runs
 * them against inputs they MUST flag and inputs they must NOT flag, with no
 * device at all. That gate imports THIS module, never a copy.
 *
 * Every expected word below is a PINNED LITERAL, deliberately not read from the
 * bundle: an audit that takes its expected value from the artifact it audits
 * goes green on a wrong declaration. When the bundle changes a word on purpose,
 * this file changes with it — that is the point.
 */

/**
 * ga_heating's change-log `source` → the reason line the log card prints after
 * the change, in the resident's words (ga-frontend-bundle 1.23.0). `resident`
 * and `valve` read as the actor alone; the rest carry "· <why>".
 */
export const SOURCE_REASON: Record<string, string> = {
  resident: 'Benutzer',
  valve: 'Benutzer',
  boost: 'Benutzer · Boost',
  absence: 'Benutzer · Urlaub',
  plan: 'System · Heizplan',
  window: 'System · Fenster',
  expiry: 'System · Zeit abgelaufen',
  balancing: 'System · Einregulierung',
};

/** One entry as ga_heating publishes it on the room (`attributes.changes`). */
export interface ChangeEntry {
  at?: string;
  kind?: string;
  from?: unknown;
  to?: unknown;
  source?: string;
}

/** One rendered line of the log card, as the browser reads it. */
export interface RenderedLine {
  when: string;
  what: string;
  why: string;
}

/**
 * The entries the card is supposed to render — mode and target changes only,
 * in the order ga_heating publishes them (newest first).
 */
export function loggableEntries(changes: ChangeEntry[] | null | undefined): ChangeEntry[] {
  return (changes ?? []).filter(e => e && (e.kind === 'mode' || e.kind === 'target'));
}

/** Strip the " · " the card puts in front of the reason span. */
export function reasonText(why: string): string {
  return (why ?? '').replace(/^\s*·\s*/, '').trim();
}

/**
 * Lines whose reason does not match the source of the entry they render.
 *
 * Pairs line i with entry i (both newest first). Returns one message per
 * mismatch; empty is the healthy answer. A source this table does not know is
 * a mismatch too — fails closed, so a new ga_heating source is a finding until
 * someone writes down what a resident should read for it.
 */
export function reasonMismatches(entries: ChangeEntry[], lines: RenderedLine[]): string[] {
  const out: string[] = [];
  const n = Math.min(entries.length, lines.length);
  for (let i = 0; i < n; i++) {
    const src = String(entries[i].source ?? '');
    const expected = SOURCE_REASON[src];
    const got = reasonText(lines[i].why);
    if (expected === undefined) {
      out.push(`line ${i}: source "${src}" has no pinned reason (rendered "${got}")`);
    } else if (got !== expected) {
      out.push(`line ${i}: source "${src}" should read "${expected}", rendered "${got}" (${lines[i].what})`);
    }
  }
  if (lines.length !== n || entries.length !== n) {
    out.push(`rendered ${lines.length} line(s) for ${entries.length} published entr(y/ies)`);
  }
  return out;
}

/** `21` → `"21,0"`, the card's own number format. */
export function deTemp(v: number): string {
  return Number(v).toFixed(1).replace('.', ',');
}

/** The text the card prints for a setpoint change, e.g. "Soll 20,0 → 21,0 °C". */
export function targetLine(from: number | null, to: number): string {
  return `Soll ${from == null ? '–' : deTemp(from)} → ${deTemp(to)} °C`;
}

// ── Wartung ─────────────────────────────────────────────────────────────────

/** Below or at these, the maintenance card must name a battery (bundle 1.23.0). */
export const BATTERY_LOW_PCT = 30;
/** What the card says when nothing needs a person. */
export const MAINTENANCE_QUIET = 'Keine Auffälligkeiten.';

/** z2m names a device's entities after its IEEE address: `0x…_battery`. */
export function ieeeOf(entityId: string): string | null {
  const object = String(entityId || '').split('.').pop() || '';
  const m = /^(0x[0-9a-f]+)/i.exec(object);
  return m ? m[1].toLowerCase() : null;
}

export interface EntityInfo {
  /** `hass.entities[id].platform` — `mobile_app` for a phone. */
  platform?: string;
  /** The area the entity is in, directly or through its device. */
  area_id?: string | null;
}

/**
 * Battery sensors the Wartung card was given that do not belong in it.
 *
 * Allowed: a `sensor.<ieee>_battery` whose IEEE is one of the room's valves,
 * and whose area (when the registry says one) is the room's. A phone
 * (`mobile_app`) is never allowed, whatever it is called or where it sits.
 */
export function foreignBatteries(
  batteries: string[],
  valveEntityIds: string[],
  roomSensorIds: string[],
  roomArea: string | null,
  info: Record<string, EntityInfo>,
): string[] {
  const own = new Set(
    [...valveEntityIds, ...roomSensorIds].map(ieeeOf).filter((k): k is string => Boolean(k)),
  );
  const out: string[] = [];
  for (const b of batteries) {
    const i = info[b] ?? {};
    if (i.platform === 'mobile_app') { out.push(`${b} (a phone — mobile_app)`); continue; }
    const k = ieeeOf(b);
    if (!k || !own.has(k)) { out.push(`${b} (not one of this room's devices)`); continue; }
    if (roomArea && i.area_id && i.area_id !== roomArea) {
      out.push(`${b} (in area ${i.area_id}, not ${roomArea})`);
    }
  }
  return out.sort();
}

/**
 * How many lines the card must show for these readings: one per battery at or
 * below the low band. A missing / empty / non-numeric reading is silence, not
 * "0 %" — the card's own rule, and the one a naive `Number("")` breaks.
 */
export function expectedLowCount(readings: (string | null | undefined)[]): number {
  let n = 0;
  for (const r of readings) {
    if (r == null) continue;
    const t = String(r).trim();
    if (t === '') continue;
    const v = Number(t);
    if (Number.isFinite(v) && v <= BATTERY_LOW_PCT) n++;
  }
  return n;
}

// ── override rows and the Profil card ───────────────────────────────────────

/** What the room card says while each override runs. */
export const OVERRIDE_LABEL = {
  ichb: 'Abgleich läuft',
  boost: 'Boost',
} as const;
/** The button that ends a boost in its own room. */
export const END_OVERRIDE = 'Beenden';
/** The Profil card's balancing controls. */
export const ICHB_START = 'Abgleich starten';
export const ICHB_CANCEL = 'Abgleich abbrechen';
/** The first ga_heating that registers `ga_heating.ichb`. */
export const ICHB_MIN_VERSION = '0.13.0';

/** `a >= b` for dotted numeric versions; a non-numeric part compares as 0. */
export function versionAtLeast(a: string, b: string): boolean {
  const pa = String(a).split('.').map(x => parseInt(x, 10) || 0);
  const pb = String(b).split('.').map(x => parseInt(x, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (d !== 0) return d > 0;
  }
  return true;
}

// ── console ─────────────────────────────────────────────────────────────────

/**
 * Console lines that mean a card did not render: HA's "Custom element doesn't
 * exist" and its German error-card heading "Konfigurationsfehler".
 */
export const CARD_FAILURE = /custom element doesn'?t exist|Konfigurationsfehler/i;

export function cardFailures(lines: string[]): string[] {
  return [...new Set((lines ?? []).filter(l => CARD_FAILURE.test(l ?? '')))];
}
