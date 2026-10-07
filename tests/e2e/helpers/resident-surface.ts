/**
 * The judgements `resident-surface.spec.ts` makes about what a resident sees.
 *
 * They live here, apart from the browser plumbing, for one reason: an
 * assertion that only ever runs against a real device can only be proven by a
 * real device, and on the day it is written there may not be one. Pulled out,
 * each judgement is a function over data — so `resident-surface-gate.spec.ts`
 * can run it against inputs it MUST flag and inputs it must NOT flag, with no
 * device at all, on every PR.
 *
 * That gate imports THIS module, never a copy of these rules. A self-test that
 * re-declares what it is testing stays green while the real thing rots, and is
 * the very failure class it was built to catch.
 */

/**
 * Stock Home Assistant panels that must never reach a resident's sidebar.
 *
 * PINNED LITERALS. Deliberately not derived from the component's own
 * `GA_HIDDEN_DEFAULT_PANELS`: an audit that takes its expected value from the
 * artifact it audits goes green on a wrong declaration. It is also the only
 * thing that can see a Core RENAME — `frontend.async_remove_panel` cannot tell
 * a renamed panel from an absent one, so the component would keep reporting
 * success while a new panel appeared in the sidebar.
 */
export const STOCK_PANELS = [
  'energy',
  'logbook',
  'history',
  'media-browser',
  'todo',
  'map',
] as const;

/** Panels that legitimately belong to a resident and must survive the sweep. */
export const EXPECTED_PANELS = ['lovelace', 'config', 'developer-tools', 'profile'] as const;

/**
 * What a NON-admin keeps. Home Assistant registers `config` and
 * `developer-tools` with `require_admin`, so a resident never has them — the
 * first run of this suite with a resident account (K31, rc39, 2026-09-16)
 * reported both as "gone". They were not gone; the list above was measured
 * with the admin account and said "resident" anyway.
 */
export const EXPECTED_PANELS_RESIDENT = ['lovelace', 'profile'] as const;

/**
 * A Zigbee IEEE address as zigbee2mqtt names a device nobody renamed —
 * 16 hex digits, with or without the `0x`.
 */
export const RADIO_ADDRESS = /\b(?:0x)?[0-9a-f]{16}\b/i;

/** The hours the heating plan's day curve must label. */
export const AXIS_LABELS = ['0', '6', '12', '18', '24'] as const;

/** Per-user personal dashboards are `ga-home-<slug>`. */
export const PERSONAL_DASHBOARD = /^ga-home-/;

export interface PanelInfo {
  url_path: string;
  title: string | null;
  component_name?: string;
}

export interface StrategyCard {
  type?: string;
  name?: string;
  title?: string;
  entity?: string;
  entities?: (string | { entity?: string; name?: string })[];
  cards?: StrategyCard[];
}
export interface StrategySection {
  type?: string;
  cards?: StrategyCard[];
}
export interface StrategyView {
  title?: string;
  path?: string;
  cards?: StrategyCard[];
  sections?: StrategySection[];
}
export interface DashboardConfig {
  views?: StrategyView[];
}

/**
 * The panels the frontend would put in the sidebar.
 *
 * Home Assistant's own rule, from `ha-sidebar.ts` / `computePanels`: a
 * non-default panel whose `title` is falsy is skipped. That is the mechanism
 * the personal dashboards are hidden BY, so it is the mechanism this has to
 * model — asking whether a panel merely EXISTS would flag boards that are
 * correctly hidden.
 */
export function sidebarPanels(panels: PanelInfo[]): PanelInfo[] {
  return panels.filter(p => Boolean(p.title));
}

/** Stock HA panels that reached the sidebar. Empty is the healthy answer. */
export function leakedStockPanels(panels: PanelInfo[]): string[] {
  const stock = STOCK_PANELS as readonly string[];
  return sidebarPanels(panels)
    .filter(p => stock.includes(p.url_path))
    .map(p => `${p.url_path} ("${p.title}")`);
}

/** Personal `ga-home-<slug>` boards that reached the sidebar. */
export function personalDashboardsInSidebar(panels: PanelInfo[]): string[] {
  return sidebarPanels(panels)
    .filter(p => PERSONAL_DASHBOARD.test(p.url_path))
    .map(p => `${p.url_path} ("${p.title}")`);
}

/**
 * Where Home Assistant keeps the developer tools, by Core version.
 *
 * MEASURED IN CORE'S SOURCE (`components/frontend/__init__.py`):
 *   - up to 2026.1  a panel of its own, `developer-tools`;
 *   - 2026.2        no longer a panel: a page of the `config` panel,
 *                   `/config/developer-tools`, with `/developer-tools/*`
 *                   redirected there;
 *   - 2026.8        renamed to `/config/tools`; both older URLs redirect.
 *
 * So from 2026.2 on, an admin keeps the developer tools by keeping `config`,
 * and a `developer-tools` entry in `hass.panels` is no longer expected. The
 * first run on Core 2026.8 (bench canary, rc8, 2026-10-07) reported it "gone"
 * while the tools were one click away.
 */
export const DEVTOOLS_PANEL_GONE_IN = '2026.2';

/** `2026.8.1` → [2026, 8, 1]; null when it is not a Core version. */
export function coreVersionParts(v: string | null | undefined): number[] | null {
  const m = /^(\d{4})\.(\d{1,2})(?:\.(\d+))?/.exec(String(v ?? '').trim());
  return m ? [Number(m[1]), Number(m[2]), Number(m[3] ?? 0)] : null;
}

/** `a >= b` for Core versions; an unreadable `a` is treated as OLD. */
export function coreAtLeast(a: string | null | undefined, b: string): boolean {
  const pa = coreVersionParts(a);
  const pb = coreVersionParts(b)!;
  if (!pa) return false;
  for (let i = 0; i < 3; i++) if (pa[i] !== pb[i]) return pa[i] > pb[i];
  return true;
}

/**
 * Panels a resident must keep that are not registered at all.
 *
 * `coreVersion` decides whether an admin still needs a `developer-tools`
 * panel (Core < 2026.2) or reaches the tools through `config` (2026.2+).
 * Unknown or unreadable → the OLD rule, so a device that cannot say its
 * version is held to the stricter list rather than let off.
 */
export function missingExpectedPanels(
  panels: PanelInfo[],
  isAdmin = true,
  coreVersion?: string | null,
): string[] {
  const present = new Set(panels.map(p => p.url_path));
  let expected: readonly string[] = isAdmin ? EXPECTED_PANELS : EXPECTED_PANELS_RESIDENT;
  if (isAdmin && coreAtLeast(coreVersion, DEVTOOLS_PANEL_GONE_IN)) {
    expected = expected.filter(p => p !== 'developer-tools');
  }
  return expected.filter(p => !present.has(p));
}

/**
 * The words the room card's running-state badge may say (`ga-thermostat-card`
 * `.act`). PINNED.
 *
 *   Heizt     hvac_action heating
 *   Leerlauf  hvac_action idle — Home Assistant's own German for it, used by
 *             the bundle since 1.22.0
 *   Bereit    idle, as bundles before 1.22.0 said it
 *   Aus       the room is off
 */
export const RUNNING_BADGES = ['Heizt', 'Leerlauf', 'Bereit', 'Aus'] as const;

/**
 * What is wrong with the running-state badges a page renders. Empty is the
 * healthy answer. No badge at all is a finding (the state is not drawn), and
 * so is any badge whose word is not pinned above — a colour or an unknown
 * word is not a statement a resident can read.
 */
export function runningBadgeProblems(badges: string[]): string[] {
  if (!badges.length) return ['no running-state badge rendered'];
  const known = RUNNING_BADGES as readonly string[];
  return [...new Set(badges.filter(b => !known.includes(b)))].map(b => `unknown badge "${b}"`);
}

/** Every card in a view, wherever the strategy chose to put it, nesting included. */
export function allCards(view: StrategyView): StrategyCard[] {
  const flatten = (cards: StrategyCard[]): StrategyCard[] =>
    cards.flatMap(c => [c, ...flatten(c.cards ?? [])]);
  return flatten([...(view.cards ?? []), ...(view.sections ?? []).flatMap(s => s.cards ?? [])]);
}

/** Every human-facing label the dashboard config puts in front of a resident. */
export function renderedLabels(cfg: DashboardConfig | null): string[] {
  const out: string[] = [];
  for (const view of cfg?.views ?? []) {
    if (view.title) out.push(view.title);
    for (const card of allCards(view)) {
      if (card.name) out.push(card.name);
      if (card.title) out.push(card.title);
      for (const row of card.entities ?? []) {
        if (typeof row !== 'string' && row.name) out.push(row.name);
      }
    }
  }
  return out;
}

/** Labels that are a radio address rather than a name. */
export function addressLikeLabels(labels: string[]): string[] {
  return labels.filter(l => RADIO_ADDRESS.test(l));
}

/** Whitespace-separated words on the page that are a radio address. */
export function addressesInText(text: string): string[] {
  return [...new Set(text.split(/\s+/).filter(w => RADIO_ADDRESS.test(w)))];
}

/** Does this dashboard config build a heating-plan card at all? */
export function hasHeatingCard(cfg: DashboardConfig | null): boolean {
  return (cfg?.views ?? []).some(v =>
    allCards(v).some(c => c.type === 'custom:ga-heating-card'),
  );
}

// ───────────────────────────────────────────────────────────────────────────
// Do the cards the bundle ships actually REGISTER in the browser?
//
// MEASURED, 2026-09-15, on a freshly flashed canary. Not one first-party card
// registered: `window.customCards` filtered to `ga-*` was empty,
// `customElements.get('ga-heating-card')` was `false`, the heating plan
// rendered Home Assistant's red "custom element doesn't exist" card, the
// *Verwalten* tab never loaded. Every card file was fetched and answered
// HTTP 200 with its `customElements.define` intact — fetched, never executed.
//
// This is the half no server can reach. `ga_manager`'s `ga.frontend_cards`
// check compares what the bundle SHIPS with what Core REGISTERED and what
// those URLs SERVE, and on that device all three of those agreed. "The module
// was delivered and did not execute" is a fact about a JavaScript runtime, and
// only a browser can witness it. That is what these judgements are for.
// ───────────────────────────────────────────────────────────────────────────

/** URL base the ga_frontend_bundle component serves its own cards under. */
export const FIRST_PARTY_URL_BASE = '/ga_frontend_bundle_first_party';

/**
 * Which custom element each shipped first-party asset is supposed to define.
 *
 * PINNED LITERALS, and deliberately NOT derived from the bundle — the same
 * reason as `STOCK_PANELS` above: an audit that takes its expected value from
 * the artifact it audits goes green on a wrong declaration.
 *
 * The mapping is not the identity, which is exactly why it has to be written
 * down. `ga-home-strategy` defines `ll-strategy-dashboard-ga-home`, not an
 * element of its own name; `ga-sidebar-default` defines NOTHING — it is a
 * side-effect module that docks the drawer — so demanding an element from it
 * would be a permanent red on every healthy device, which is an off switch
 * with extra steps.
 */
export const EXPECTED_ELEMENTS: Record<string, string | null> = {
  'ga-heating-card': 'ga-heating-card',
  'ga-master-card': 'ga-master-card',
  'ga-thermostat-card': 'ga-thermostat-card',
  // The whole-home heating controls on the Profil view (bundle 1.18.0).
  'ga-heating-actions-card': 'ga-heating-actions-card',
  // "Aktivität" under each room's thermostat (bundle 1.22.0) and "Wartung"
  // under it (1.23.0). Measured unmapped on BOSv1.4.0-rc6, 2026-10-06 — this
  // check went red, as built to, until they were written down here.
  'ga-heating-log-card': 'ga-heating-log-card',
  'ga-maintenance-card': 'ga-maintenance-card',
  'ga-home-strategy': 'll-strategy-dashboard-ga-home',
  'ga-sidebar-default': null,
  // Side-effect module: watches the registry swap and reports elements that
  // could not register (bundle 1.15.0). Defines nothing itself.
  'ga-registry-guard': null,
};

/**
 * Card types that must advertise themselves in `window.customCards`.
 *
 * That array is what the dashboard card picker reads, and it is what was
 * measured empty on the canary. A card can define its element and forget to
 * push here — then it renders but cannot be added — so this is a second,
 * independent reading, not a restatement of `customElements.get`.
 */
export const ADVERTISED_CARD_TYPES = [
  'ga-heating-card',
  'ga-master-card',
  'ga-thermostat-card',
  'ga-heating-log-card',
  'ga-maintenance-card',
] as const;

/**
 * Home Assistant's message when a `custom:` card names an element nobody
 * defined. This exact string is what the resident was looking at.
 */
export const CUSTOM_ELEMENT_ERROR = /custom element doesn'?t exist:?\s*([a-z0-9][a-z0-9-]*)/i;

/** The element HA renders a broken card into. */
export const HA_ERROR_ELEMENT = 'HUI-ERROR-CARD';

export interface CustomCardEntry {
  type?: string;
  name?: string;
}

/**
 * The path part of a module URL, however the page happened to spell it.
 *
 * The device spec collects module URLs from three places and they do not agree
 * on shape: `performance` resource entries are ABSOLUTE
 * (`http://host:8123/ga_.../x.js?v=1`), an `import("…")` call in the page is
 * relative, and a `src` attribute read via `.src` is absolute again. Pulled
 * out here so the normalisation is fixture-tested rather than living inside a
 * `page.evaluate` string that only a device can run.
 */
export function modulePath(url: string): string {
  let rest = url;
  const scheme = rest.indexOf('://');
  if (scheme !== -1) {
    const slash = rest.indexOf('/', scheme + 3);
    rest = slash === -1 ? '/' : rest.slice(slash);
  }
  return rest.split('?')[0].split('#')[0];
}

/**
 * The first-party assets the running bundle injected, read off the modules the
 * page loaded. This is "what the bundle ships" as the BROWSER can see it —
 * there is no filesystem here.
 */
export function firstPartyAssetIds(moduleSrcs: (string | null)[]): string[] {
  const prefix = FIRST_PARTY_URL_BASE + '/';
  const out: string[] = [];
  for (const src of moduleSrcs) {
    if (!src) continue;
    const path = modulePath(src);
    if (!path.startsWith(prefix)) continue;
    const id = path.slice(prefix.length).split('/')[0];
    if (id && !out.includes(id)) out.push(id);
  }
  return out;
}

/**
 * Assets this file has never been told about.
 *
 * FAILS CLOSED. A card added to the bundle and not added to
 * `EXPECTED_ELEMENTS` would otherwise be silently skipped — the check would
 * keep passing while covering less, which is how a guard rots without ever
 * going red. A new card is a finding until somebody maps it.
 */
export function unmappedAssets(assetIds: string[]): string[] {
  return assetIds.filter(id => !(id in EXPECTED_ELEMENTS)).sort();
}

/**
 * Shipped assets whose element never registered.
 *
 * `defined` is `customElements.get(name) !== undefined` per element, read in
 * the page. Assets mapped to `null` define no element and are skipped by
 * design, not by accident.
 */
export function unregisteredAssets(
  assetIds: string[],
  defined: Record<string, boolean>,
): string[] {
  const out: string[] = [];
  for (const id of assetIds) {
    const element = EXPECTED_ELEMENTS[id];
    if (!element) continue;
    if (!defined[element]) out.push(`${id} (${element})`);
  }
  return out.sort();
}

/** Every element name these assets are expected to have defined. */
export function expectedElementNames(assetIds: string[]): string[] {
  return assetIds
    .map(id => EXPECTED_ELEMENTS[id])
    .filter((e): e is string => Boolean(e))
    .sort();
}

/** GA card types missing from `window.customCards`. */
export function missingAdvertisedCards(customCards: CustomCardEntry[]): string[] {
  const present = new Set((customCards ?? []).map(c => c?.type).filter(Boolean));
  return (ADVERTISED_CARD_TYPES as readonly string[]).filter(t => !present.has(t));
}

/**
 * Element names Home Assistant reported as missing, from the page's own text.
 *
 * Deduped: the same undefined element on four cards is ONE cause, and a list
 * that repeats itself reads as a bigger problem than it is.
 */
export function missingElementErrors(texts: string[]): string[] {
  const out = new Set<string>();
  for (const text of texts ?? []) {
    for (const line of (text ?? '').split('\n')) {
      const m = line.match(CUSTOM_ELEMENT_ERROR);
      if (m) out.add(m[1].toLowerCase());
    }
  }
  return [...out].sort();
}
