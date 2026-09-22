import { test, expect } from '../fixtures/device';
import { haLogin } from '../helpers/auth';
import { waitForHA } from '../helpers/ha-api';

/**
 * What a resident waits for, in seconds, with the number printed every run.
 *
 * Measured on K31 on 2026-09-22 over the resident URL: the heating card was in
 * the DOM at 11.3 s in one run and 28 s in another, because all thirteen
 * vendored community cards were injected on every dashboard load — 6.1 MB
 * ahead of our own 13-23 KB assets, plotly-graph-card alone 3.1 MB in 10.2 s.
 * ga-frontend-bundle 1.16.0 injects the two we place (155 KB) and puts a
 * deterministic byte budget on that set.
 *
 * This is the other half, and it is the half that can lie: a device on a mesh
 * link, a cold Core, a busy runner. So the budget is generous enough that a
 * red here means something changed, not that the weather did — and the
 * MEASUREMENT is always logged, so a slow drift is visible long before the
 * threshold is reached. A number nobody reads until it trips is a number that
 * trips as a surprise.
 */
// EIGHT SECONDS, from pressing log-in to seeing the heating card, on a device
// reached over the mesh. Not derived from today's number — that would be an
// audit taking its expected value from the artifact it audits. It is the
// product statement: longer than this and a resident opens the app, sees a
// grey page, and closes it again.
//
// It is RED on a device today, on purpose: 12.4 s / 5710 KB measured on K31 on
// 2026-09-22, with plotly-graph-card (3053 KB) at the top of the list although
// nothing places it. It goes green when ga-frontend-bundle 1.16.0 reaches the
// device — which is the pair of proofs this check owes: red against the broken
// state, green against the fixed one.
const BUDGET_MS = Number(process.env.GA_LOAD_BUDGET_MS || 8000);

test.describe('Resident load budget', () => {
  // No retry. Home Assistant ships a service worker, so a second attempt is
  // served from cache — measured on K31: 10.0 s / 7438 KB on a cold context,
  // 3.7 s / 1986 KB on the retry. A retry would turn the very thing this
  // measures into a green tick.
  test.describe.configure({ retries: 0 });

  test('a resident reaches their heating card inside the budget', async ({ page, deviceUrl }) => {
    test.setTimeout(3 * 60_000);
    await waitForHA(deviceUrl);

    // A FRESH context, because the subject is the first visit: an empty HTTP
    // cache and no service worker, the way a phone that has never been here
    // arrives. Clearing caches inside an existing context does not reproduce
    // it — the document you need in order to clear them has already warmed
    // the HTTP cache, which is how an earlier version of this check measured
    // 4.8 s for something that takes 10.
    const browser = page.context().browser();
    expect(browser, 'no browser handle — cannot open a cold context').toBeTruthy();
    const ctx = await browser!.newContext({ ignoreHTTPSErrors: true });
    const fresh = await ctx.newPage();

    let cardMs = -1;
    let payload = { totalKB: 0, top: [] as string[] };
    try {
      const t0 = Date.now();
      await haLogin(fresh, deviceUrl);
      await fresh.goto(deviceUrl);
      await fresh.waitForURL(/lovelace|ga-home/, { timeout: 60_000 });

      const deadline = Date.now() + 90_000; // measure well past the budget
      while (Date.now() < deadline) {
        const found = (await fresh.evaluate(`(() => {
          const deep = (root, out = []) => {
            for (const el of Array.from(root.querySelectorAll('*'))) {
              out.push(el);
              if (el.shadowRoot) deep(el.shadowRoot, out);
            }
            return out;
          };
          return deep(document).some(e => e.tagName === 'GA-HEATING-CARD' || e.tagName === 'GA-THERMOSTAT-CARD');
        })()`)) as boolean;
        if (found) { cardMs = Date.now() - t0; break; }
        await fresh.waitForTimeout(250);
      }

      // What the browser actually pulled, so a red says WHY without a second
      // run: a community card back in the injected set shows up as megabytes.
      payload = (await fresh.evaluate(`(() => {
        const r = performance.getEntriesByType('resource');
        const total = r.reduce((s, e) => s + (e.transferSize || 0), 0);
        const top = r.slice().sort((a, b) => (b.transferSize || 0) - (a.transferSize || 0)).slice(0, 3)
          .map(e => e.name.split('/').slice(-1)[0].slice(0, 30) + '=' + Math.round((e.transferSize || 0) / 1024) + 'KB');
        return { totalKB: Math.round(total / 1024), top };
      })()`)) as { totalKB: number; top: string[] };
    } finally {
      await ctx.close();
    }

    // Always logged, pass or fail: a threshold nobody watches until it trips
    // trips as a surprise, and a slow drift is only visible as a series.
    console.log(
      `LOAD BUDGET cold login+dashboard card=${cardMs < 0 ? 'never' : (cardMs / 1000).toFixed(1) + 's'} ` +
      `budget=${(BUDGET_MS / 1000).toFixed(1)}s payload=${payload.totalKB}KB heaviest=${payload.top.join(',')}`,
    );

    expect(cardMs, 'no GA heating/thermostat card appeared within 90 s — the card never mounted, which is not a budget miss').toBeGreaterThan(0);
    expect(
      cardMs,
      `a resident waited ${(cardMs / 1000).toFixed(1)} s from login to their heating card (budget ${(BUDGET_MS / 1000).toFixed(1)} s). ` +
        `The page pulled ${payload.totalKB} KB; heaviest: ${payload.top.join(', ')}. ` +
        "If a community card is back in the injected set, ga-frontend-bundle's byte budget names it.",
    ).toBeLessThanOrEqual(BUDGET_MS);
  });
});
