import { test, expect } from '../fixtures/device';
import { waitForHA } from '../helpers/ha-api';
import { execFileSync } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';

/**
 * Sub-User Join — Master-User Management Plane E2E (ADR-0006)
 *
 * Drives the real browser journey of a household Sub-User self-registering via
 * the same link (`/greenautarky-join`). Since 2026-07 the join REUSES the real
 * onboarding wizard components (max code-share, "so upstream wie möglich"):
 *   - `ga-setup-pin` in join mode collects the 6-digit invite PIN
 *   - `ga-setup-create-user` in join mode reuses the ha-form + password-strength
 *     UI, posting to /api/greenautarky_site/sub_user/join
 *   - the panel detects /greenautarky-join and starts at the PIN step
 * The standalone HTML join form is gone; /greenautarky-join now 302-redirects
 * into the wizard (`/greenautarky-setup.html?join=1`).
 *
 * REQUIRES (like the dashboard/auth tests):
 *   DEVICE_IP        — the canary iHost (SSH + HTTP), component PATCHED with the
 *                      sub-user branch (greenautarky-onboarding feat/sub-user-*).
 *   HA_TOKEN | HA_ADMIN_PASS — admin auth, used to flag a master + mint an invite.
 *
 * Auto-skips if auth is missing OR the component isn't patched (join route 404).
 *
 * Screenshots for the docs/KB are written to SHOT_DIR (default test-results/join-shots).
 *
 * Run:
 *   DEVICE_IP=100.126.35.139 HA_ADMIN_PASS=... npx playwright test tests/sub-user-join.spec.ts --project=desktop
 */

const SUB_NAME = 'E2E SubUser';
const SUB_PASSWORD = 'SubUserE2E!2026'; // strong: upper+lower+digit+symbol, >= 8
const SHOT_DIR = process.env.SHOT_DIR || path.resolve(__dirname, '../test-results/join-shots');

function shot(name: string): string {
  fs.mkdirSync(SHOT_DIR, { recursive: true });
  return path.join(SHOT_DIR, name);
}

function ssh(cmd: string): string {
  const ip = process.env.DEVICE_IP;
  if (!ip) throw new Error('DEVICE_IP not set');
  const key =
    process.env.SSH_KEY ||
    process.env.HOME + '/Nextcloud2/GreenAutarky/security_store/HomeassistantGreen0.pem';
  const port = process.env.SSH_PORT || '22222';
  // execFileSync with an args array: `cmd` is passed to ssh as ONE argument, so
  // its own quotes (python -c '…', printf '…') survive intact for the remote
  // shell — no fragile local quote-wrapping.
  const args = [
    '-o', 'StrictHostKeyChecking=no',
    '-o', 'UserKnownHostsFile=/dev/null',
    '-o', 'PubkeyAcceptedAlgorithms=+ssh-rsa',
    '-o', 'HostKeyAlgorithms=+ssh-rsa',
    '-i', key, '-p', port, `root@${ip}`, cmd,
  ];
  return execFileSync('ssh', args, { timeout: 60_000 }).toString().trim();
}

async function getToken(deviceUrl: string): Promise<string> {
  if (process.env.HA_TOKEN) return process.env.HA_TOKEN;
  const clientId = `${deviceUrl}/`;
  const flow = await (
    await fetch(`${deviceUrl}/auth/login_flow`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ client_id: clientId, handler: ['homeassistant', null], redirect_uri: clientId }),
    })
  ).json();
  const cred = await (
    await fetch(`${deviceUrl}/auth/login_flow/${flow.flow_id}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        client_id: clientId,
        username: process.env.HA_ADMIN_USER || 'admin',
        password: process.env.HA_ADMIN_PASS,
      }),
    })
  ).json();
  if (!cred.result) throw new Error('login failed — check HA_ADMIN_PASS');
  const tok = await (
    await fetch(`${deviceUrl}/auth/token`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'authorization_code', code: cred.result, client_id: clientId }),
    })
  ).json();
  return tok.access_token as string;
}

async function api(deviceUrl: string, token: string, method: string, apiPath: string, body?: unknown) {
  const res = await fetch(`${deviceUrl}/api/greenautarky_site${apiPath}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = await res.json().catch(() => ({}));
  return { status: res.status, json };
}

function skipGuards() {
  if (!process.env.DEVICE_IP) test.skip(true, 'DEVICE_IP required');
  if (!process.env.HA_TOKEN && !process.env.HA_ADMIN_PASS)
    test.skip(true, 'Auth required — set HA_TOKEN or HA_ADMIN_PASS');
}

/**
 * Wait for the create-user step to actually render its ha-form (the selectors
 * resolve async chunks). Returns the rendered <input> count so callers can
 * assert the form is live. Pierces shadow roots.
 */
async function waitCreateUserInputs(page: import('@playwright/test').Page): Promise<number> {
  const handle = await page.waitForFunction(
    () => {
      const panel = document.querySelector('ha-panel-greenautarky-setup');
      const cu = panel?.shadowRoot?.querySelector('ga-setup-create-user');
      if (!cu || !(cu as HTMLElement & { shadowRoot?: ShadowRoot }).shadowRoot) return false;
      let n = 0;
      const walk = (root: ParentNode) =>
        root.querySelectorAll('*').forEach((el) => {
          if ((el as HTMLElement).tagName === 'INPUT') n++;
          const sr = (el as HTMLElement & { shadowRoot?: ShadowRoot }).shadowRoot;
          if (sr) walk(sr);
        });
      walk((cu as HTMLElement & { shadowRoot: ShadowRoot }).shadowRoot);
      return n >= 3 ? n : false;
    },
    { timeout: 30_000 },
  );
  return (await handle.jsonValue()) as number;
}

test.describe('Sub-User join via onboarding wizard (ADR-0006)', () => {
  let token = '';
  let ownerId = '';
  let invitePin = '';
  let createdUserId = '';

  test.beforeAll(async ({ deviceUrl }) => {
    skipGuards();
    await waitForHA(deviceUrl, 60_000);

    // Component patched? /greenautarky-join must redirect into the wizard (302).
    const probe = await fetch(`${deviceUrl}/greenautarky-join`, { redirect: 'manual' }).catch(() => null);
    if (!probe || (probe.status !== 302 && probe.status !== 200))
      test.skip(true, 'component not patched — /greenautarky-join did not redirect');

    token = await getToken(deviceUrl);

    // Resolve the owner user id from the device auth store.
    ownerId = ssh(
      `docker exec homeassistant python3 -c 'import json;d=json.load(open("/config/.storage/auth"))["data"];print(next(u["id"] for u in d["users"] if u.get("is_owner") and not u.get("system_generated")))'`,
    );
    expect(ownerId).toMatch(/^[0-9a-f]{32}$/);

    // Flag the owner as master (file read per-call → no restart needed).
    ssh(
      `mkdir -p /mnt/data/supervisor/homeassistant/ga && printf '%s' '{"masters":[{"ha_user_id":"${ownerId}"}]}' > /mnt/data/supervisor/homeassistant/ga/ga-master-users.json`,
    );

    // Mint an invite as the master (owner). 6-digit numeric PIN (reuses wizard PIN step).
    const inv = await api(deviceUrl, token, 'POST', '/sub_user/invite', {});
    expect(inv.status).toBe(200);
    invitePin = inv.json.pin;
    expect(invitePin).toMatch(/^\d{6}$/);
  });

  test('join link redirects into the wizard PIN step', async ({ page, deviceUrl }) => {
    skipGuards();
    await page.goto(`${deviceUrl}/greenautarky-join`);
    await expect(page).toHaveURL(/greenautarky-setup\.html\?join=1/);
    await expect(page.locator('ga-setup-pin')).toBeAttached({ timeout: 20_000 });
    // Join-specific copy (not the device-PIN copy).
    await expect(page.locator('ga-setup-pin')).toContainText('Einladungs-PIN', { timeout: 10_000 });
    await page.screenshot({ path: shot('join-1-pin.png'), animations: 'disabled' });
  });

  test('sub-user self-registers through the wizard', async ({ page, deviceUrl }) => {
    skipGuards();
    await page.goto(`${deviceUrl}/greenautarky-join`);
    await expect(page.locator('ga-setup-pin')).toBeAttached({ timeout: 20_000 });

    // PIN step: entering 6 digits auto-submits and advances to create-user.
    await page.locator('ga-setup-pin input').first().fill(invitePin);

    // create-user step renders the ha-form (name + password + confirm).
    await expect(page.locator('ga-setup-create-user')).toBeAttached({ timeout: 20_000 });
    const inputCount = await waitCreateUserInputs(page);
    expect(inputCount).toBeGreaterThanOrEqual(3);

    await page.locator('input[autocomplete="name"]').fill(SUB_NAME);
    await page.locator('input[autocomplete="new-password"]').nth(0).fill(SUB_PASSWORD);
    await page.locator('input[autocomplete="new-password"]').nth(1).fill(SUB_PASSWORD);

    // Password-strength (reused component) must show "Stark" and enable submit.
    await expect(page.locator('ga-setup-create-user')).toContainText('Stark', { timeout: 10_000 });

    // Datenschutz consent (required in join mode since onboarding 1.1.0):
    // the consent copy + link are shown and the submit stays gated until checked.
    await expect(page.locator('ga-setup-create-user')).toContainText('Datenschutzerklärung');
    await expect(
      page.locator('ga-setup-create-user a[href="https://greenautarky.com/datenschutz"]'),
    ).toBeAttached();
    await page.locator('ga-setup-create-user ha-checkbox').click();
    await page.screenshot({ path: shot('join-2-account.png'), animations: 'disabled' });

    // Submit → join endpoint → Non-Admin user + auto-login → redirect to /.
    await page.locator('ga-setup-create-user ha-button').click({ force: true });
    await page.waitForURL((url) => url.pathname === '/' || url.pathname.startsWith('/lovelace'), {
      timeout: 30_000,
    });
    await page.screenshot({ path: shot('join-3-logged-in.png'), animations: 'disabled' });
  });

  test('created sub-user is a Non-Admin under the master, with a linked Person', async ({ deviceUrl }) => {
    skipGuards();
    // via the master API: the new user appears in the master's list
    const list = await api(deviceUrl, token, 'GET', '/sub_user/list');
    expect(list.status).toBe(200);
    const mine = list.json.sub_users.find(
      (u: { username: string; user_id: string }) => u.username === 'e2e_subuser',
    );
    expect(mine, 'new sub-user present in master list').toBeTruthy();
    createdUserId = mine.user_id;

    // via the device store: non-admin + parent == owner + linked person + consent.
    //
    // NOT "system-users in group_ids" any more. Since entity scoping shipped, a
    // sub-user is placed in exactly one ga_scope_<uid> group whose policy is the
    // compiled allow-list of their assigned areas — membership of system-users
    // would hand them the unrestricted default and defeat the scoping. Measured
    // on K31, 2026-09-03: two sub-users in ga_scope_* and one older one still in
    // system-users, so both shapes are accepted and the invariant asserted is
    // the one that matters: NOT an admin, NOT the owner, under this master.
    //
    // Reported per condition. The single compound boolean this replaces printed
    // "False" and nothing else, so every failure needed a manual investigation
    // on the device before anyone knew which half was broken.
    const check = ssh(
      `docker exec homeassistant python3 -c 'import json;a=json.load(open("/config/.storage/auth"))["data"];u=next(x for x in a["users"] if x["id"]=="${mine.user_id}");g=u.get("group_ids",[]);st=json.load(open("/config/.storage/greenautarky_site"))["data"];rec=st.get("sub_users",{}).get("${mine.user_id}",{});ps=json.load(open("/config/.storage/person"))["data"]["items"];print(json.dumps({"not_admin":"system-admin" not in g,"not_owner":not u.get("is_owner"),"scoped_or_user":any(x.startswith("ga_scope_") for x in g) or "system-users" in g,"master_is_owner":rec.get("master")=="${ownerId}","person_linked":any(x.get("user_id")=="${mine.user_id}" for x in ps),"consent_v1":rec.get("consent",{}).get("datenschutz",{}).get("version")==1}))'`,
    );
    const facts = JSON.parse(check) as Record<string, boolean>;
    const wrong = Object.entries(facts)
      .filter(([, ok]) => !ok)
      .map(([name]) => name);
    expect(wrong, `sub-user invariants that do not hold: ${wrong.join(', ')}`).toEqual([]);
  });

  test('a wrong invite PIN is rejected at submit', async ({ page, deviceUrl }) => {
    skipGuards();
    await page.goto(`${deviceUrl}/greenautarky-join`);
    await expect(page.locator('ga-setup-pin')).toBeAttached({ timeout: 20_000 });

    // In join mode the PIN step does NOT verify against the device — it forwards
    // any 6-digit PIN; the join endpoint rejects a bad invite at submit time.
    await page.locator('ga-setup-pin input').first().fill('000000');
    await expect(page.locator('ga-setup-create-user')).toBeAttached({ timeout: 20_000 });
    await waitCreateUserInputs(page);

    await page.locator('input[autocomplete="name"]').fill('Nope');
    await page.locator('input[autocomplete="new-password"]').nth(0).fill(SUB_PASSWORD);
    await page.locator('input[autocomplete="new-password"]').nth(1).fill(SUB_PASSWORD);
    await page.locator('ga-setup-create-user ha-checkbox').click();
    await page.locator('ga-setup-create-user ha-button').click({ force: true });

    // An error alert appears; no navigation to /.
    await expect(page.locator('ga-setup-create-user ha-alert')).toBeVisible({ timeout: 15_000 });
    await expect(page).toHaveURL(/greenautarky-setup\.html/);
  });

  test.afterAll(async ({ deviceUrl }) => {
    if (!token) return;
    // Best-effort cleanup: delete the test sub-user (WS) + remove the flag file.
    try {
      if (!createdUserId) {
        const list = await api(deviceUrl, token, 'GET', '/sub_user/list');
        createdUserId =
          list.json.sub_users?.find((u: { username: string; user_id: string }) => u.username === 'e2e_subuser')
            ?.user_id || '';
      }
      if (createdUserId) {
        const ws = new WebSocket(`${deviceUrl.replace('http', 'ws')}/api/websocket`);
        await new Promise<void>((resolve) => {
          let id = 0;
          ws.onmessage = (ev) => {
            const m = JSON.parse(ev.data as string);
            if (m.type === 'auth_required') ws.send(JSON.stringify({ type: 'auth', access_token: token }));
            else if (m.type === 'auth_ok')
              ws.send(JSON.stringify({ id: ++id, type: 'config/auth/delete', user_id: createdUserId }));
            else if (m.type === 'result') { ws.close(); resolve(); }
          };
          ws.onerror = () => resolve();
          setTimeout(() => { ws.close(); resolve(); }, 10_000);
        });
      }
    } catch {
      /* best-effort */
    }
    try {
      ssh('rm -f /mnt/data/supervisor/homeassistant/ga/ga-master-users.json');
    } catch {
      /* best-effort */
    }
  });
});
