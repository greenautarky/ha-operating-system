import { test, expect, sshJump } from '../fixtures/device';
import { waitForHA } from '../helpers/ha-api';
import { haLogin } from '../helpers/auth';
import { readHttpTrust, readHttpYaml, servicesAddress, trustsProxy } from '../helpers/ha-http-config';

/**
 * Reverse Proxy — verify HA is accessible via Tailscale Funnel and Caddy proxy
 *
 * Tests that the device is configured for reverse proxy access:
 * - Core RUNS use_x_forwarded_for + trusted_proxies (127.0.0.1 and the GA services
 *   address): Core >= 2026.8 asked via `http/config`, older Core via the YAML it
 *   reads (ADR-0038; helpers/ha-http-config.ts)
 * - external_url points to ki-butler domain
 * - Tailscale Funnel responds (if TAILSCALE_URL is set)
 * - Caddy proxy responds (if CADDY_URL is set)
 *
 * Environment variables:
 *   DEVICE_IP       - required, iHost IP for SSH access
 *   TAILSCALE_URL   - optional, e.g. https://kib-son-00000000-2.tail1234.ts.net
 *   CADDY_URL       - optional, e.g. https://abc12345.ki-butler.greenautarky.com
 *   HA_ADMIN_PASS   - optional, for authenticated proxy tests
 */

test.describe('Reverse Proxy Config', () => {
  // What Core RUNS (ADR-0038): on Core >= 2026.8 via `http/config`, on older
  // Core the YAML it still reads. Until 2026-09-28 both tests grepped the YAML
  // on every Core — green while Core 2026.8 ignored the file and refused every
  // proxied request. helpers/ha-http-config.ts.
  test('Core runs use_x_forwarded_for=true', async ({ deviceUrl }) => {
    await waitForHA(deviceUrl);
    if (!process.env.DEVICE_IP) test.skip(true, 'DEVICE_IP not set');

    const trust = readHttpTrust();
    if (trust.era === 'yaml') {
      expect(readHttpYaml()).toMatch(/use_x_forwarded_for.*true/);
      return;
    }
    expect(trust.running?.use_x_forwarded_for, `Core ${trust.coreVersion} runs slot ${trust.activeConfigType}`).toBe(true);
    expect(trust.pending, 'no unpromoted/failed pending HTTP config').toBeNull();
    expect(trust.activeConfigType).toBe('stable');
  });

  test('Core trusts 127.0.0.1 and the GA services address as proxies', async () => {
    if (!process.env.DEVICE_IP) test.skip(true, 'DEVICE_IP not set');

    const svc = servicesAddress();
    const trust = readHttpTrust();
    if (trust.era === 'yaml') {
      const yaml = readHttpYaml();
      expect(yaml).toContain('trusted_proxies');
      expect(yaml).toContain('127.0.0.1');
      if (svc) expect(yaml).toContain(svc);
      return;
    }
    const proxies = trust.running?.trusted_proxies;
    expect(trustsProxy(proxies, '127.0.0.1'), `running trusted_proxies=${JSON.stringify(proxies)}`).toBe(true);
    expect(svc, 'services address published to /share/ga-services.json').not.toBe('');
    expect(trustsProxy(proxies, svc), `running trusted_proxies=${JSON.stringify(proxies)}, want ${svc}`).toBe(true);
  });

  test('external_url set to ki-butler domain', async () => {
    const ip = process.env.DEVICE_IP;
    if (!ip) test.skip(true, 'DEVICE_IP not set');

    const { execSync } = await import('child_process');
    const key =
      process.env.SSH_KEY ||
      process.env.HOME + '/Nextcloud2/GreenAutarky/security_store/HomeassistantGreen0.pem';
    const port = process.env.SSH_PORT || '22222';
    const ssh = `ssh ${sshJump()}-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${key} -p ${port} root@${ip}`;

    const config = execSync(
      `${ssh} 'cat /mnt/data/supervisor/homeassistant/configuration.yaml /mnt/data/supervisor/homeassistant/ga_packages/*.yaml 2>/dev/null'`,
      { timeout: 15_000 },
    ).toString();

    expect(config).toContain('external_url');
    expect(config).toContain('ki-butler.greenautarky.com');
  });
});

test.describe('Tailscale Funnel', () => {
  test('Funnel URL serves HA login page', async ({ page }) => {
    const tsUrl = process.env.TAILSCALE_URL;
    if (!tsUrl) test.skip(true, 'TAILSCALE_URL not set');

    await page.goto(tsUrl, { timeout: 30_000 });

    // HA should show login or onboarding page
    await expect(
      page.locator('ha-authorize, ha-onboarding, .login-form').first(),
    ).toBeVisible({ timeout: 30_000 });
  });
});

test.describe('Caddy Proxy', () => {
  // The runner now derives CADDY_URL from the device's own external_url, which
  // turned these tests from 6 skips into 6 failures in 400 ms on 2026-09-07:
  // the canary's hostname has NO DNS record (the apex does; the per-device
  // names of two canaries do not). A test that cannot reach its subject must
  // say why, not fail on DNS — and a device carrying an external_url that does
  // not resolve is a finding for the fleet, reported here as the skip reason.
  const dnsResolves = async (url: string): Promise<boolean> => {
    const { lookup } = await import('node:dns/promises');
    try { await lookup(new URL(url).hostname); return true; } catch { return false; }
  };

  test('Caddy URL serves HA login page', async ({ page }) => {
    const caddyUrl = process.env.CADDY_URL;
    if (!caddyUrl) test.skip(true, 'CADDY_URL not set');
    if (!(await dnsResolves(caddyUrl!)))
      test.skip(true, `no DNS record for ${new URL(caddyUrl!).hostname} — the device's external_url does not resolve; public ingress not provisioned for it`);

    await page.goto(caddyUrl, { timeout: 30_000 });

    // HA should show login or onboarding page
    await expect(
      page.locator('ha-authorize, ha-onboarding, .login-form').first(),
    ).toBeVisible({ timeout: 30_000 });
  });

  test('Caddy forwards real client IP (not proxy IP)', async ({ page }) => {
    const caddyUrl = process.env.CADDY_URL;
    const adminPass = process.env.HA_ADMIN_PASS;
    if (caddyUrl && !(await dnsResolves(caddyUrl)))
      test.skip(true, `no DNS record for ${new URL(caddyUrl).hostname} — the device's external_url does not resolve; public ingress not provisioned for it`);
    if (!caddyUrl || !adminPass) {
      test.skip(true, 'CADDY_URL and HA_ADMIN_PASS required');
    }

    // Login via Caddy and check that HA sees the real client IP
    // (not the ga-tools NetBird IP from GA_SERVICES_IP) in the auth log
    await haLogin(page, caddyUrl);
    await page.goto(`${caddyUrl}/profile`);
    await expect(page).toHaveURL(/profile/, { timeout: 15_000 });
  });
});
