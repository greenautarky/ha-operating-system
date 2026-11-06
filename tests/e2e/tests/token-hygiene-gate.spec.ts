import { test, expect } from '@playwright/test';
import { createServer, IncomingMessage, Server, ServerResponse } from 'http';
import { AddressInfo } from 'net';
import { mkdtempSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { WebSocketServer } from 'ws';
import { loginWithCredentials } from '../helpers/auth';
import {
  assertBounded,
  countE2eTokens,
  listRefreshTokens,
  readLedger,
  revokeLedger,
} from '../helpers/token-hygiene';
import teardown from '../global-teardown';

/**
 * Odoo #1565 gate - runs with no device and no browser.
 *
 * A stub Home Assistant speaks the three real endpoints the suite uses
 * (login_flow, /auth/token incl. action=revoke, websocket auth/refresh_tokens)
 * and keeps a table of refresh tokens. The SUBJECT (auth.ts, token-hygiene.ts,
 * global-teardown.ts) is the real code; only the far end of the wire is a stub.
 *
 *   MUST flag   : a run whose revoke is ignored leaves its tokens in HA; a count
 *                 above the limit makes the teardown throw.
 *   MUST NOT    : a clean run leaves zero; an unreachable device keeps ledger
 *                 entries for the next run instead of dropping them.
 */

interface Stub {
  server: Server;
  url: string;
  tokens: Map<string, { client_id: string }>;
  revokeCalls: () => number;
  close: () => Promise<void>;
}

async function startStub(opts: { ignoreRevoke?: boolean; preload?: number } = {}): Promise<Stub> {
  const tokens = new Map<string, { client_id: string }>();
  let n = 0;
  let revokes = 0;
  const mint = (client_id: string) => {
    const rt = `rt-${++n}`;
    tokens.set(rt, { client_id });
    return rt;
  };
  const read = (req: IncomingMessage) =>
    new Promise<string>(r => {
      let b = '';
      req.on('data', c => (b += c));
      req.on('end', () => r(b));
    });
  const server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
    const body = await read(req);
    res.setHeader('Content-Type', 'application/json');
    if (req.url === '/auth/login_flow' && req.method === 'POST') return res.end(JSON.stringify({ flow_id: 'f1' }));
    if (req.url === '/auth/login_flow/f1') return res.end(JSON.stringify({ result: 'code-1' }));
    if (req.url === '/auth/token') {
      const p = new URLSearchParams(body);
      if (p.get('action') === 'revoke') {
        revokes++;
        if (!opts.ignoreRevoke) tokens.delete(p.get('token') || '');
        return res.end('{}');
      }
      const issued = { token_type: 'Bearer', expires_in: 1800 } as Record<string, unknown>;
      issued['access_token'] = 'at';
      issued['refresh_token'] = mint(p.get('client_id')!);
      return res.end(JSON.stringify(issued));
    }
    res.statusCode = 404;
    res.end('{}');
  });
  const wss = new WebSocketServer({ server, path: '/api/websocket' });
  wss.on('connection', sock => {
    sock.send(JSON.stringify({ type: 'auth_required' }));
    sock.on('message', raw => {
      const m = JSON.parse(raw.toString());
      if (m.type === 'auth') sock.send(JSON.stringify({ type: 'auth_ok' }));
      if (m.type === 'auth/refresh_tokens')
        sock.send(
          JSON.stringify({
            id: m.id,
            type: 'result',
            success: true,
            result: [...tokens.entries()].map(([id, t]) => ({ id, client_id: t.client_id, type: 'normal' })),
          }),
        );
    });
  });
  await new Promise<void>(r => server.listen(0, '127.0.0.1', r));
  const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  for (let i = 0; i < (opts.preload || 0); i++) mint(`${url}/`);
  return {
    server,
    url,
    tokens,
    revokeCalls: () => revokes,
    close: () => new Promise<void>(r => (wss.close(), server.close(() => r()))),
  };
}

test.beforeEach(() => {
  process.env.GA_E2E_TOKEN_LEDGER = join(mkdtempSync(join(tmpdir(), 'ga-e2e-ledger-')), 'ledger.jsonl');
});

test('MUST-NOT flag: logins are recorded, and teardown revokes every one', async () => {
  const stub = await startStub();
  try {
    for (let i = 0; i < 4; i++) await loginWithCredentials(stub.url, 'u', 'p');
    expect(stub.tokens.size).toBe(4);
    expect(readLedger()).toHaveLength(4);
    const r = await revokeLedger();
    expect(r).toEqual({ revoked: 4, failed: 0 });
    expect(stub.tokens.size).toBe(0);
    expect(readLedger()).toHaveLength(0);
  } finally {
    await stub.close();
  }
});

test('MUST flag: a revoke the server ignores leaves tokens behind (proves the check can see leakage)', async () => {
  const stub = await startStub({ ignoreRevoke: true });
  try {
    for (let i = 0; i < 3; i++) await loginWithCredentials(stub.url, 'u', 'p');
    await revokeLedger();
    expect(countE2eTokens(await listRefreshTokens(stub.url, 'at'), stub.url)).toBe(3);
  } finally {
    await stub.close();
  }
});

test('MUST-NOT lose: an unreachable device keeps the ledger entries for the next run', async () => {
  const stub = await startStub();
  await loginWithCredentials(stub.url, 'u', 'p');
  await stub.close();
  const r = await revokeLedger();
  expect(r).toEqual({ revoked: 0, failed: 1 });
  expect(readLedger()).toHaveLength(1);
});

test('bound: assertBounded passes at the limit and throws above it', () => {
  expect(() => assertBounded(15, 15)).not.toThrow();
  expect(() => assertBounded(16, 15)).toThrow(/bound exceeded/);
  expect(() => assertBounded(Number.NaN, 15)).toThrow(/bound exceeded/);
});

test('global teardown end to end: revokes, then FAILS when old tokens push the count over the limit', async () => {
  const stub = await startStub({ preload: 20 });
  const saved = { ...process.env };
  try {
    Object.assign(process.env, { DEVICE_URL: stub.url, HA_ADMIN_PASS: 'p', GA_E2E_MAX_TOKENS: '15' });
    delete process.env.HA_TOKEN;
    await loginWithCredentials(stub.url, 'admin', 'p'); // a suite login, ledgered
    await expect(teardown()).rejects.toThrow(/bound exceeded/);
    expect(stub.tokens.size).toBe(20); // ledgered one + teardown's own probe were revoked
  } finally {
    process.env = saved;
    await stub.close();
  }
});

test('global teardown end to end: green and leaves nothing of its own when the account is clean', async () => {
  const stub = await startStub();
  const saved = { ...process.env };
  try {
    Object.assign(process.env, { DEVICE_URL: stub.url, HA_ADMIN_PASS: 'p', GA_E2E_MAX_TOKENS: '15' });
    delete process.env.HA_TOKEN;
    await loginWithCredentials(stub.url, 'admin', 'p');
    await loginWithCredentials(stub.url, 'admin', 'p');
    await teardown();
    expect(stub.tokens.size).toBe(0);
    expect(stub.revokeCalls()).toBe(3); // two ledgered + the probe
  } finally {
    process.env = saved;
    await stub.close();
  }
});
