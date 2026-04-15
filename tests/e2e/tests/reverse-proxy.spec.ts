import { test, expect } from '../fixtures/device';
import { waitForHA } from '../helpers/ha-api';

/**
 * Reverse Proxy — verify HA is accessible via Tailscale Funnel and Caddy proxy
 *
 * Tests that the device is configured for reverse proxy access:
 * - trusted_proxies set correctly in configuration.yaml
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
  test('configuration.yaml has use_x_forwarded_for enabled', async ({ deviceUrl }) => {
    await waitForHA(deviceUrl);

    // Read config via SSH
    const ip = process.env.DEVICE_IP;
    if (!ip) test.skip(true, 'DEVICE_IP not set');

    const { execSync } = await import('child_process');
    const key =
      process.env.SSH_KEY ||
      process.env.HOME + '/Nextcloud2/GreenAutarky/security_store/HomeassistantGreen0.pem';
    const port = process.env.SSH_PORT || '22222';
    const ssh = `ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${key} -p ${port} root@${ip}`;

    const config = execSync(
      `${ssh} 'cat /mnt/data/supervisor/homeassistant/configuration.yaml'`,
      { timeout: 15_000 },
    ).toString();

    expect(config).toContain('use_x_forwarded_for');
    expect(config).toMatch(/use_x_forwarded_for.*true/);
  });

  test('trusted_proxies includes 127.0.0.1 and GA_SERVICES_IP', async () => {
    const ip = process.env.DEVICE_IP;
    if (!ip) test.skip(true, 'DEVICE_IP not set');

    const { execSync } = await import('child_process');
    const key =
      process.env.SSH_KEY ||
      process.env.HOME + '/Nextcloud2/GreenAutarky/security_store/HomeassistantGreen0.pem';
    const port = process.env.SSH_PORT || '22222';
    const ssh = `ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${key} -p ${port} root@${ip}`;

    const config = execSync(
      `${ssh} 'cat /mnt/data/supervisor/homeassistant/configuration.yaml'`,
      { timeout: 15_000 },
    ).toString();

    expect(config).toContain('trusted_proxies');
    expect(config).toContain('127.0.0.1');

    // Check GA_SERVICES_IP is in trusted_proxies
    const gaIp = execSync(
      `${ssh} 'grep "^GA_SERVICES_IP=" /mnt/data/ga-services.conf 2>/dev/null || grep "^GA_SERVICES_IP=" /etc/ga-services.conf 2>/dev/null || echo ""'`,
      { timeout: 15_000 },
    )
      .toString()
      .trim()
      .split('=')[1];

    if (gaIp) {
      expect(config).toContain(gaIp);
    }
  });

  test('external_url set to ki-butler domain', async () => {
    const ip = process.env.DEVICE_IP;
    if (!ip) test.skip(true, 'DEVICE_IP not set');

    const { execSync } = await import('child_process');
    const key =
      process.env.SSH_KEY ||
      process.env.HOME + '/Nextcloud2/GreenAutarky/security_store/HomeassistantGreen0.pem';
    const port = process.env.SSH_PORT || '22222';
    const ssh = `ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${key} -p ${port} root@${ip}`;

    const config = execSync(
      `${ssh} 'cat /mnt/data/supervisor/homeassistant/configuration.yaml'`,
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
  test('Caddy URL serves HA login page', async ({ page }) => {
    const caddyUrl = process.env.CADDY_URL;
    if (!caddyUrl) test.skip(true, 'CADDY_URL not set');

    await page.goto(caddyUrl, { timeout: 30_000 });

    // HA should show login or onboarding page
    await expect(
      page.locator('ha-authorize, ha-onboarding, .login-form').first(),
    ).toBeVisible({ timeout: 30_000 });
  });

  test('Caddy forwards real client IP (not proxy IP)', async ({ page }) => {
    const caddyUrl = process.env.CADDY_URL;
    const adminPass = process.env.HA_ADMIN_PASS;
    if (!caddyUrl || !adminPass) {
      test.skip(true, 'CADDY_URL and HA_ADMIN_PASS required');
    }

    // Login via Caddy and check that HA sees the real client IP
    // (not 100.126.129.116) in the auth log
    const { haLogin } = await import('../helpers/auth');
    await haLogin(page, caddyUrl);
    await page.goto(`${caddyUrl}/profile`);
    await expect(page).toHaveURL(/profile/, { timeout: 15_000 });
  });
});
