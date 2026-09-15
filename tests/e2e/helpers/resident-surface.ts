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

/** Panels a resident must keep that are not registered at all. */
export function missingExpectedPanels(panels: PanelInfo[]): string[] {
  const present = new Set(panels.map(p => p.url_path));
  return (EXPECTED_PANELS as readonly string[]).filter(p => !present.has(p));
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
