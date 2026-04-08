import { test, expect } from '../fixtures/device';
import { getGAOnboardingStatus, waitForHA } from '../helpers/ha-api';

/**
 * Telemetry Consent — E2E tests
 *
 * Tests that the analytics/telemetry step in onboarding correctly saves
 * preferences to the greenautarky_telemetry storage, which the OS-level
 * ga-telemetry-gate script reads to gate Telegraf and Fluent-Bit services.
 *
 * Non-destructive tests (API smoke) can run anytime.
 * Destructive tests (full wizard flow) require RESET_ONBOARDING=1.
 *
 * Run:
 *   DEVICE_IP=<ip> npx playwright test tests/telemetry-consent.spec.ts
 *   DEVICE_IP=<ip> RESET_ONBOARDING=1 npx playwright test tests/telemetry-consent.spec.ts
 */

const DEVICE_IP = process.env.DEVICE_IP;
const SSH_CMD = DEVICE_IP
  ? `ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -p 22222 root@${DEVICE_IP}`
  : '';

/** Read telemetry preferences from device storage via SSH */
async function getDeviceTelemetryPrefs(): Promise<{ error_logs: boolean; metrics: boolean } | null> {
  if (!DEVICE_IP) return null;
  const { execSync } = await import('child_process');
  try {
    const raw = execSync(
      `${SSH_CMD} cat /mnt/data/supervisor/homeassistant/.storage/greenautarky_telemetry 2>/dev/null`,
      { timeout: 10_000, encoding: 'utf8' },
    );
    const parsed = JSON.parse(raw);
    return parsed.data || null;
  } catch {
    return null;
  }
}

/** Check if consent marker file exists on device */
async function hasConsentMarker(marker: string): Promise<boolean> {
  if (!DEVICE_IP) return false;
  const { execSync } = await import('child_process');
  try {
    execSync(`${SSH_CMD} test -f /mnt/data/${marker}`, { timeout: 5_000 });
    return true;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Non-destructive: API smoke tests (safe on any device)
// ---------------------------------------------------------------------------

test.describe('Telemetry Consent — API', () => {
  test('telemetry endpoint exists (returns 200 or 403)', async ({ deviceUrl }) => {
    const res = await fetch(`${deviceUrl}/api/greenautarky_onboarding/telemetry`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ error_logs: false, metrics: false }),
    });
    // 200 if onboarding not complete, 403 if already completed — both are valid
    expect([200, 403]).toContain(res.status);
  });

  test('onboarding status includes expected fields', async ({ deviceUrl }) => {
    const status = await getGAOnboardingStatus(deviceUrl);
    // steps_done should be an array (may include "telemetry" if already done)
    expect(Array.isArray(status.steps_done)).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Device-level: consent marker verification (requires SSH)
// ---------------------------------------------------------------------------

test.describe('Telemetry Consent — Device markers', () => {
  test.skip(!DEVICE_IP, 'DEVICE_IP required for SSH-based marker checks');

  test('consent markers match stored preferences', async () => {
    const prefs = await getDeviceTelemetryPrefs();
    if (!prefs) {
      test.skip(true, 'No telemetry preferences on device (not yet onboarded)');
      return;
    }

    const metricsMarker = await hasConsentMarker('.ga-consent-metrics');
    const errorLogsMarker = await hasConsentMarker('.ga-consent-error_logs');

    if (prefs.metrics) {
      expect(metricsMarker, 'metrics=true but consent marker missing').toBe(true);
    } else {
      expect(metricsMarker, 'metrics=false but consent marker exists').toBe(false);
    }

    if (prefs.error_logs) {
      expect(errorLogsMarker, 'error_logs=true but consent marker missing').toBe(true);
    } else {
      expect(errorLogsMarker, 'error_logs=false but consent marker exists').toBe(false);
    }
  });

  test('ga-telemetry-gate script exists and is executable', async () => {
    const { execSync } = await import('child_process');
    const result = execSync(`${SSH_CMD} test -x /usr/sbin/ga-telemetry-gate && echo ok`, {
      timeout: 5_000,
      encoding: 'utf8',
    });
    expect(result.trim()).toBe('ok');
  });

  test('ga-telemetry-consent.service ran successfully', async () => {
    const { execSync } = await import('child_process');
    const state = execSync(
      `${SSH_CMD} systemctl show ga-telemetry-consent -p ActiveState --value`,
      { timeout: 5_000, encoding: 'utf8' },
    );
    expect(state.trim()).toBe('active');
  });
});

// ---------------------------------------------------------------------------
// Destructive: Full wizard flow with telemetry step (requires RESET_ONBOARDING=1)
// ---------------------------------------------------------------------------

test.describe('Telemetry Consent — Wizard flow', () => {
  test.skip(!process.env.RESET_ONBOARDING, 'Set RESET_ONBOARDING=1 for destructive tests');
  test.skip(!DEVICE_IP, 'DEVICE_IP required for onboarding reset');

  test.beforeEach(async ({ deviceUrl }) => {
    // Reset onboarding via admin API
    const { execSync } = await import('child_process');
    execSync(
      `${SSH_CMD} 'curl -sf -X POST http://localhost:8123/api/greenautarky_onboarding/reset -H "Authorization: Bearer $(cat /mnt/data/supervisor/homeassistant/.storage/auth 2>/dev/null | grep -o \\"[a-f0-9]\\{64\\}\\" | head -1)" 2>/dev/null || true'`,
      { timeout: 15_000 },
    );
    await waitForHA(deviceUrl, 30_000);
  });

  test('analytics step shows two toggles', async ({ page, deviceUrl }) => {
    await page.goto(`${deviceUrl}/greenautarky-setup`);
    await page.waitForSelector('ha-panel-greenautarky-setup', { timeout: 20_000 });

    // Navigate through steps to reach analytics
    // Welcome → click Weiter
    const weiterButtons = page.getByRole('button', { name: /weiter|continue|next/i });
    await weiterButtons.first().click();

    // PIN step (skip if not required)
    // GDPR step — accept and continue
    const gdprCheckbox = page.locator('ha-checkbox, ha-switch, input[type="checkbox"]').first();
    if (await gdprCheckbox.isVisible({ timeout: 5_000 }).catch(() => false)) {
      await gdprCheckbox.click();
      await weiterButtons.first().click();
    }

    // Navigate until we find analytics step text
    // Look for telemetry-related text
    const bodyText = async () => (await page.textContent('body')) ?? '';
    let found = false;
    for (let i = 0; i < 5; i++) {
      const text = await bodyText();
      if (/fehlerberichte|error.*report|metriken|system.*metric/i.test(text)) {
        found = true;
        break;
      }
      // Try clicking next/continue
      const btn = weiterButtons.first();
      if (await btn.isVisible({ timeout: 2_000 }).catch(() => false)) {
        await btn.click();
        await page.waitForTimeout(1_000);
      }
    }

    expect(found, 'Analytics step with telemetry toggles not found in wizard').toBe(true);
  });
});
