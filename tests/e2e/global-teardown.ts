import { loginWithCredentials } from './helpers/auth';
import {
  DEFAULT_MAX_TOKENS,
  assertBounded,
  countE2eTokens,
  listRefreshTokens,
  revokeLedger,
  revokeRefreshToken,
} from './helpers/token-hygiene';
import { haBaseUrl } from './helpers/ha-url';

/**
 * Odoo #1565: revoke every refresh token this suite minted, then check that the
 * test account's token count on the device stays bounded.
 */
export default async function globalTeardown(): Promise<void> {
  const { revoked, failed } = await revokeLedger();
  if (revoked || failed) console.log(`[token-hygiene] revoked ${revoked} refresh token(s), ${failed} left for next run`);

  const password = process.env.HA_ADMIN_PASS || process.env.HA_ADMIN_PASSWORD;
  if (process.env.HA_TOKEN || !password || (!process.env.DEVICE_IP && !process.env.DEVICE_URL)) return;

  // Count with a fresh login of our own, then revoke that one too.
  const hassUrl = haBaseUrl();
  const t = await loginWithCredentials(hassUrl, process.env.HA_ADMIN_USER || 'admin', password, { record: false });
  try {
    const count = countE2eTokens(await listRefreshTokens(hassUrl, t.access_token), hassUrl) - 1; // minus our own
    const max = Number(process.env.GA_E2E_MAX_TOKENS || DEFAULT_MAX_TOKENS);
    console.log(`[token-hygiene] ${count} e2e login token(s) remain on the account (limit ${max})`);
    assertBounded(count, max);
  } finally {
    if (t.refresh_token) await revokeRefreshToken(hassUrl, t.refresh_token);
  }
}
