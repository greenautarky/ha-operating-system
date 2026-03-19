import type { Page } from '@playwright/test';

/**
 * HA authentication helpers.
 *
 * Implements the HA OAuth-like auth flow to obtain an access token, then
 * injects it into the browser session via localStorage so subsequent page
 * loads are authenticated.
 *
 * Priority:
 *   1. HA_TOKEN env var (pre-created long-lived token)
 *   2. HA_ADMIN_USER + HA_ADMIN_PASS env vars (full login flow)
 */

interface HassTokens {
  access_token: string;
  token_type: string;
  expires_in: number;
  refresh_token?: string;
  expires?: number;
  hassUrl?: string;
  clientId?: string;
}

/**
 * Log in to HA and inject the auth state into the Playwright page.
 * Call this before navigating to authenticated pages.
 *
 * @throws if neither HA_TOKEN nor HA_ADMIN_PASS is set
 */
export async function haLogin(page: Page, hassUrl: string): Promise<void> {
  const token = process.env.HA_TOKEN;
  if (token) {
    await injectToken(page, hassUrl, { access_token: token, token_type: 'Bearer' });
    return;
  }

  const username = process.env.HA_ADMIN_USER || 'admin';
  const password = process.env.HA_ADMIN_PASS;
  if (!password) {
    throw new Error(
      'Authentication required: set HA_TOKEN or HA_ADMIN_USER + HA_ADMIN_PASS',
    );
  }

  const tokens = await loginWithCredentials(hassUrl, username, password);
  await injectToken(page, hassUrl, tokens);
}

async function loginWithCredentials(
  hassUrl: string,
  username: string,
  password: string,
): Promise<HassTokens> {
  const clientId = `${hassUrl}/`;

  // Step 1: start the login flow
  const flowRes = await fetch(`${hassUrl}/auth/login_flow`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      client_id: clientId,
      handler: ['homeassistant', null],
      redirect_uri: clientId,
    }),
  });
  if (!flowRes.ok) throw new Error(`Login flow start failed: ${flowRes.status}`);
  const { flow_id } = (await flowRes.json()) as { flow_id: string };

  // Step 2: submit credentials
  const credRes = await fetch(`${hassUrl}/auth/login_flow/${flow_id}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ client_id: clientId, username, password }),
  });
  if (!credRes.ok) throw new Error(`Credential submission failed: ${credRes.status}`);
  const credData = (await credRes.json()) as { result?: string };
  if (!credData.result) {
    throw new Error('Login failed: no auth code returned — check credentials');
  }

  // Step 3: exchange code for tokens
  const tokenRes = await fetch(`${hassUrl}/auth/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      code: credData.result,
      client_id: clientId,
    }),
  });
  if (!tokenRes.ok) throw new Error(`Token exchange failed: ${tokenRes.status}`);
  return (await tokenRes.json()) as HassTokens;
}

async function injectToken(
  page: Page,
  hassUrl: string,
  tokens: Partial<HassTokens>,
): Promise<void> {
  // HA reads auth state from localStorage['hassTokens'] on load
  await page.goto(hassUrl, { waitUntil: 'domcontentloaded' });
  await page.evaluate(
    ([url, t]) => {
      const stored = {
        ...t,
        hassUrl: url,
        clientId: `${url}/`,
        expires: Date.now() + 1_800_000,
      };
      localStorage.setItem('hassTokens', JSON.stringify(stored));
    },
    [hassUrl, tokens] as [string, Partial<HassTokens>],
  );
}
