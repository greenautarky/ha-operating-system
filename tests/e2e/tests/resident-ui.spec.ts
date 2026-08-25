import { test, expect } from '../fixtures/device';
import { haLogin } from '../helpers/auth';
import { waitForHA } from '../helpers/ha-api';

/**
 * Does the resident actually SEE their home?
 *
 * Everything else in this suite checks that the device is set up. Nothing
 * checked the last step: that a person logging in is shown their rooms and
 * their thermostats. On 2026-08-25 that step was broken on K31 for hours —
 * rooms, radiators, a finished onboarding, every device check green, and an
 * empty screen — and it was found by a human looking at it.
 *
 * TWO DESIGN DECISIONS, BOTH PAID FOR THE SAME DAY.
 *
 * 1. It asserts the GENERATED CONFIG, not the DOM. The `ga-home` strategy
 *    builds room views as `sections`, so the cards live in
 *    `views[].sections[].cards[]` and `views[].cards` is legitimately empty.
 *    Counting card elements in the DOM read that as "no cards" on a dashboard
 *    that was completely fine. A DOM assertion also fails on render timing,
 *    which produces flaky red that teaches people to re-run rather than look.
 *
 * 2. The WebSocket is a PRECONDITION, checked first and reported separately.
 *    Home Assistant's frontend gets its state over `/api/websocket`; without
 *    it the page renders nothing at all. Measuring through an SSH tunnel that
 *    dropped WebSockets produced a perfect imitation of a broken UI for
 *    several minutes. If that check fails, every assertion below is
 *    meaningless and must not be reported as a UI defect.
 *
 * Requires credentials for a RESIDENT account (not the admin owner):
 *   HA_ADMIN_USER / HA_ADMIN_PASS, or HA_TOKEN.
 */

interface StrategyCard { type?: string }
interface StrategySection { type?: string; cards?: StrategyCard[] }
interface StrategyView {
  title?: string;
  path?: string;
  cards?: StrategyCard[];
  sections?: StrategySection[];
}

function skipIfNoAuth() {
  if (!process.env.HA_TOKEN && !process.env.HA_ADMIN_PASS) {
    test.skip(
      true,
      'Resident UI tests require auth — set HA_TOKEN or HA_ADMIN_USER + HA_ADMIN_PASS',
    );
  }
}

/** Every card type in a view, wherever the strategy chose to put it. */
function cardTypes(view: StrategyView): string[] {
  const direct = (view.cards ?? []).map(c => c.type ?? '');
  const inSections = (view.sections ?? []).flatMap(s =>
    (s.cards ?? []).map(c => c.type ?? ''),
  );
  return [...direct, ...inSections].filter(Boolean);
}

/** The dashboard config the frontend is actually rendering from. */
async function renderedConfig(page: import('@playwright/test').Page) {
  return page.evaluate(() => {
    const deep = (root: ParentNode, out: Element[] = []): Element[] => {
      for (const el of Array.from(root.querySelectorAll('*'))) {
        out.push(el);
        const sr = (el as HTMLElement & { shadowRoot?: ShadowRoot }).shadowRoot;
        if (sr) deep(sr, out);
      }
      return out;
    };
    const panel = deep(document).find(
      e => e.tagName === 'HUI-ROOT' || e.tagName === 'HA-PANEL-LOVELACE',
    ) as (Element & { lovelace?: { config?: unknown } }) | undefined;
    return (panel?.lovelace?.config ?? null) as { views?: StrategyView[] } | null;
  });
}

test.describe('Resident UI', () => {
  test.beforeEach(skipIfNoAuth);

  test('the WebSocket connects — everything below depends on it', async ({
    page,
    deviceUrl,
  }) => {
    await waitForHA(deviceUrl);
    await haLogin(page, deviceUrl);

    const failures: string[] = [];
    page.on('websocket', ws => {
      ws.on('socketerror', err => failures.push(String(err)));
    });

    await page.goto(deviceUrl);
    await page.waitForURL(/lovelace/, { timeout: 30_000 });
    await page.waitForTimeout(4_000);

    // A rendered config is only obtainable once the connection is live, so its
    // presence is the proof — a passing assertion here is what makes the rest
    // of this file mean anything.
    const cfg = await renderedConfig(page);
    expect(
      cfg,
      `No dashboard config: the frontend never connected. WebSocket errors:\n${
        failures.join('\n') || '(none reported — check reverse proxies and tunnels)'
      }\nEvery other assertion in this file would fail for this reason, not because the UI is broken.`,
    ).not.toBeNull();
  });

  test('every room with a radiator shows a GA thermostat card', async ({
    page,
    deviceUrl,
  }) => {
    await waitForHA(deviceUrl);
    await haLogin(page, deviceUrl);
    await page.goto(deviceUrl);
    await page.waitForURL(/lovelace/, { timeout: 30_000 });
    await page.waitForTimeout(4_000);

    const cfg = await renderedConfig(page);
    expect(cfg, 'no dashboard config — see the WebSocket test').not.toBeNull();

    const views = cfg?.views ?? [];
    // Room views are the ones the strategy builds per area. The fixed views
    // (overview, manage, roomless) are excluded by path so this does not
    // silently pass on a device with no rooms at all.
    const fixed = new Set(['haushalt', 'verwalten', 'ohne-raum']);
    const rooms = views.filter(v => v.path && !fixed.has(v.path));

    // Coverage first. A loop over zero rooms passes every assertion inside it,
    // which is exactly how a broken dashboard reports itself as healthy.
    expect(
      rooms.length,
      `No room views in the dashboard. Views found: ${views
        .map(v => v.path)
        .join(', ') || '(none)'}`,
    ).toBeGreaterThan(0);

    const withoutThermostat = rooms
      .filter(v => !cardTypes(v).some(t => t.includes('ga-thermostat-card')))
      .map(v => `${v.path} → [${cardTypes(v).join(', ') || 'no cards at all'}]`);

    expect(
      withoutThermostat,
      `Room views without a GA thermostat card:\n${withoutThermostat.join('\n')}`,
    ).toEqual([]);
  });

  test('no room view is empty', async ({ page, deviceUrl }) => {
    await waitForHA(deviceUrl);
    await haLogin(page, deviceUrl);
    await page.goto(deviceUrl);
    await page.waitForURL(/lovelace/, { timeout: 30_000 });
    await page.waitForTimeout(4_000);

    const cfg = await renderedConfig(page);
    expect(cfg, 'no dashboard config — see the WebSocket test').not.toBeNull();

    const empty = (cfg?.views ?? [])
      .filter(v => cardTypes(v).length === 0)
      .map(v => v.path ?? v.title ?? '(unnamed)');

    expect(
      empty,
      `Views rendering nothing at all: ${empty.join(', ')}. A tab a resident ` +
        'can open and find blank is the shape this file exists to catch.',
    ).toEqual([]);
  });

  test('the overview names the rooms it found', async ({ page, deviceUrl }) => {
    await waitForHA(deviceUrl);
    await haLogin(page, deviceUrl);
    await page.goto(deviceUrl);
    await page.waitForURL(/lovelace/, { timeout: 30_000 });
    await page.waitForTimeout(4_000);

    const cfg = await renderedConfig(page);
    const titles = (cfg?.views ?? []).map(v => v.title).filter(Boolean);

    // The tab strip is what a resident navigates by. Tabs rendering while the
    // views behind them are empty was the exact failure on K31, so this is
    // deliberately asserted SEPARATELY from the card checks above rather than
    // folded into them.
    expect(titles.length, `Dashboard has no tabs at all`).toBeGreaterThan(1);
  });
});
