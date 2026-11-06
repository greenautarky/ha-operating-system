import { appendFileSync, existsSync, readFileSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

/**
 * Refresh-token hygiene for the e2e account (Odoo #1565).
 *
 * Every password login (helpers/auth.ts) makes HA store another refresh token
 * for the test account, and nothing ever deleted them: on a staging device the
 * count only went up. Two halves, both here so a gate spec can drive them
 * against a stub HA with no device:
 *
 *   1. LEDGER   - each minted refresh token is appended to a file; the global
 *                 teardown revokes every entry (a run that crashed leaves its
 *                 entries for the next teardown, so a crash cannot leak twice).
 *   2. BOUND    - after the revoke, count the account's remaining tokens for
 *                 the e2e client and FAIL if above MAX. The count is read from
 *                 HA (WebSocket auth/refresh_tokens), not from the ledger: the
 *                 ledger only knows what this suite minted, the bound is about
 *                 what HA actually holds.
 */

export const DEFAULT_MAX_TOKENS = 15;

export function ledgerPath(): string {
  return process.env.GA_E2E_TOKEN_LEDGER || join(tmpdir(), 'ga-e2e-refresh-tokens.jsonl');
}

export interface LedgerEntry {
  hassUrl: string;
  refresh_token: string;
}

export function recordRefreshToken(hassUrl: string, refresh_token: string | undefined): void {
  if (!refresh_token) return;
  appendFileSync(ledgerPath(), JSON.stringify({ hassUrl, refresh_token }) + '\n', { mode: 0o600 });
}

export function readLedger(): LedgerEntry[] {
  const p = ledgerPath();
  if (!existsSync(p)) return [];
  return readFileSync(p, 'utf8')
    .split('\n')
    .filter(Boolean)
    .map(l => JSON.parse(l) as LedgerEntry);
}

/** HA answers 200 to a revoke whether or not the token existed (RFC 7009). */
export async function revokeRefreshToken(hassUrl: string, rt: string): Promise<boolean> {
  const res = await fetch(`${hassUrl}/auth/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams([
      ['token', rt],
      ['action', 'revoke'],
    ]),
  });
  return res.ok;
}

/**
 * Revoke every ledger entry. Entries that fail to revoke stay in the ledger
 * (retried by the next teardown); the file is rewritten to hold only those.
 * Returns {revoked, failed}.
 */
export async function revokeLedger(): Promise<{ revoked: number; failed: number }> {
  const entries = readLedger();
  const keep: LedgerEntry[] = [];
  let revoked = 0;
  for (const e of entries) {
    let ok = false;
    try {
      ok = await revokeRefreshToken(e.hassUrl, e.refresh_token);
    } catch {
      ok = false; // device unreachable: keep for next time
    }
    if (ok) revoked++;
    else keep.push(e);
  }
  writeFileSync(ledgerPath(), keep.map(e => JSON.stringify(e) + '\n').join(''), { mode: 0o600 });
  return { revoked, failed: keep.length };
}

interface WsRefreshToken {
  id: string;
  client_id: string | null;
  type: string;
}

/** Ask HA (websocket auth/refresh_tokens) for the calling user's tokens. */
export async function listRefreshTokens(hassUrl: string, bearer: string): Promise<WsRefreshToken[]> {
  // `ws` is a devDependency: Node 20 has no global WebSocket.
  const { default: WebSocket } = await import('ws');
  const wsUrl = hassUrl.replace(/^http/, 'ws') + '/api/websocket';
  return new Promise((resolve, reject) => {
    const sock = new WebSocket(wsUrl);
    const timer = setTimeout(() => {
      sock.terminate();
      reject(new Error('token count: websocket timed out'));
    }, 15_000);
    const done = (fn: () => void) => {
      clearTimeout(timer);
      sock.close();
      fn();
    };
    sock.on('error', err => done(() => reject(err)));
    sock.on('message', raw => {
      const m = JSON.parse(raw.toString());
      if (m.type === 'auth_required') sock.send(JSON.stringify({ type: 'auth', access_token: bearer }));
      else if (m.type === 'auth_ok') sock.send(JSON.stringify({ id: 1, type: 'auth/refresh_tokens' }));
      else if (m.type === 'auth_invalid') done(() => reject(new Error('token count: auth_invalid')));
      else if (m.type === 'result' && m.id === 1) {
        if (m.success) done(() => resolve(m.result as WsRefreshToken[]));
        else done(() => reject(new Error(`token count: ${JSON.stringify(m.error)}`)));
      }
    });
  });
}

/**
 * Normal (login) tokens of the test account, any client_id: the e2e client_id
 * is the URL the suite was pointed at (a tunnel, a mesh IP, a LAN IP), so the
 * pile is spread over several of them. Long-lived tokens are not counted.
 */
export function countE2eTokens(tokens: WsRefreshToken[], _hassUrl?: string): number {
  return tokens.filter(t => t.type === 'normal').length;
}

export function assertBounded(count: number, max: number = DEFAULT_MAX_TOKENS): void {
  if (!(count <= max)) {
    throw new Error(
      `e2e refresh-token bound exceeded: HA holds ${count} login tokens for the test account, limit ${max}. ` +
        `Something mints tokens without revoking them (or old ones were never pruned): ` +
        `delete them in Profile > Security, or raise GA_E2E_MAX_TOKENS knowingly.`,
    );
  }
}
