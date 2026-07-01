import { test, expect } from '../fixtures/device';
import { waitForHA } from '../helpers/ha-api';
import { execFileSync } from 'child_process';

/**
 * Sub-User Join — Master-User Management Plane E2E (ADR-0006)
 *
 * Drives the real browser journey of a household Sub-User self-registering via
 * the same link (`/greenautarky-join`): enter invite-PIN + password + display
 * name → account created. Mirrors the existing onboarding E2E.
 *
 * REQUIRES (like the dashboard/auth tests):
 *   DEVICE_IP        — the canary iHost (SSH + HTTP), component PATCHED with the
 *                      sub-user branch (greenautarky-onboarding feat/sub-user-*).
 *   HA_TOKEN | HA_ADMIN_PASS — admin auth, used to flag a master + mint an invite.
 *
 * Auto-skips if auth is missing OR the component isn't patched (join route 404).
 *
 * Run:
 *   DEVICE_IP=100.126.35.139 HA_ADMIN_PASS=... npx playwright test tests/sub-user-join.spec.ts --project=desktop
 */

const SUB_NAME = 'E2E SubUser';
const SUB_PASSWORD = 'e2e-sub-pw-12345';

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

async function api(deviceUrl: string, token: string, method: string, path: string, body?: unknown) {
  const res = await fetch(`${deviceUrl}/api/greenautarky_onboarding${path}`, {
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

test.describe('Sub-User join (ADR-0006)', () => {
  let token = '';
  let ownerId = '';
  let invitePin = '';
  let createdUsername = '';

  test.beforeAll(async ({ deviceUrl }) => {
    skipGuards();
    await waitForHA(deviceUrl, 60_000);

    // Component patched? (join route must exist)
    const probe = await fetch(`${deviceUrl}/greenautarky-join`).catch(() => null);
    if (!probe || probe.status !== 200)
      test.skip(true, 'component not patched — /greenautarky-join is not 200');

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

    // Mint an invite as the master.
    const inv = await api(deviceUrl, token, 'POST', '/sub_user/invite', {});
    expect(inv.status).toBe(200);
    invitePin = inv.json.pin;
    expect(invitePin).toBeTruthy();
  });

  test('join page renders the form', async ({ page, deviceUrl }) => {
    skipGuards();
    await page.goto(`${deviceUrl}/greenautarky-join`);
    await expect(page.locator('#pin')).toBeVisible();
    await expect(page.locator('#password')).toBeVisible();
    await expect(page.locator('#submit')).toBeVisible();
  });

  test('sub-user self-registers with a valid invite', async ({ page, deviceUrl }) => {
    skipGuards();
    await page.goto(`${deviceUrl}/greenautarky-join`);
    await page.locator('#name').fill(SUB_NAME);
    await page.locator('#pin').fill(invitePin);
    await page.locator('#password').fill(SUB_PASSWORD);
    await page.locator('#password2').fill(SUB_PASSWORD);
    await page.locator('#submit').click();

    const msg = page.locator('#msg.ok');
    await expect(msg).toBeVisible({ timeout: 15_000 });
    await expect(msg).toContainText(/Konto erstellt/i);
    createdUsername = (await msg.locator('code').textContent())?.trim() || '';
    expect(createdUsername).toBeTruthy();
  });

  test('created sub-user is a Non-Admin under the master', async ({ deviceUrl }) => {
    skipGuards();
    // via the master API: the new user appears in the master's list
    const list = await api(deviceUrl, token, 'GET', '/sub_user/list');
    expect(list.status).toBe(200);
    const mine = list.json.sub_users.find((u: { username: string; user_id: string }) => u.username === createdUsername);
    expect(mine, 'new sub-user present in master list').toBeTruthy();

    // via the device store: Non-Admin group + parent == owner
    const check = ssh(
      `docker exec homeassistant python3 -c 'import json;a=json.load(open("/config/.storage/auth"))["data"];u=next(x for x in a["users"] if x["id"]=="${mine.user_id}");g=u.get("group_ids",[]);st=json.load(open("/config/.storage/greenautarky_onboarding"))["data"];p=st.get("sub_users",{}).get("${mine.user_id}",{}).get("master");print(("system-users" in g) and ("system-admin" not in g) and (not u.get("is_owner")) and (p=="${ownerId}"))'`,
    );
    expect(check).toBe('True');
  });

  test('a wrong invite PIN is rejected', async ({ page, deviceUrl }) => {
    skipGuards();
    await page.goto(`${deviceUrl}/greenautarky-join`);
    await page.locator('#name').fill('Nope');
    await page.locator('#pin').fill('WRONGPIN');
    await page.locator('#password').fill(SUB_PASSWORD);
    await page.locator('#password2').fill(SUB_PASSWORD);
    await page.locator('#submit').click();
    await expect(page.locator('#msg.err')).toBeVisible({ timeout: 15_000 });
  });

  test.afterAll(async ({ deviceUrl }) => {
    if (!token) return;
    // Best-effort cleanup: delete the test sub-user (WS) + remove the flag file.
    try {
      if (createdUsername) {
        const list = await api(deviceUrl, token, 'GET', '/sub_user/list');
        const mine = list.json.sub_users?.find((u: { username: string; user_id: string }) => u.username === createdUsername);
        if (mine?.user_id) {
          const ws = new WebSocket(`${deviceUrl.replace('http', 'ws')}/api/websocket`);
          await new Promise<void>((resolve, reject) => {
            let id = 0;
            ws.onmessage = (ev) => {
              const m = JSON.parse(ev.data as string);
              if (m.type === 'auth_required') ws.send(JSON.stringify({ type: 'auth', access_token: token }));
              else if (m.type === 'auth_ok') ws.send(JSON.stringify({ id: ++id, type: 'config/auth/delete', user_id: mine.user_id }));
              else if (m.type === 'result') { ws.close(); resolve(); }
            };
            ws.onerror = () => reject(new Error('ws error'));
            setTimeout(() => { ws.close(); resolve(); }, 10_000);
          });
        }
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
