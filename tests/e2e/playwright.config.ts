import { defineConfig, devices } from '@playwright/test';
import { haBaseUrl } from './helpers/ha-url';

/**
 * GA OS E2E Test Configuration
 *
 * Tests run against a real iHost device. Set DEVICE_IP (or DEVICE_URL) before running.
 * Optional auth via HA_ADMIN_USER + HA_ADMIN_PASS (or HA_TOKEN) for dashboard tests.
 * Set RESET_ONBOARDING=1 to enable destructive onboarding flow tests.
 *
 * Quick start:
 *   DEVICE_IP=192.168.1.100 npx playwright test
 *
 * With auth (dashboard tests):
 *   DEVICE_IP=192.168.1.100 HA_ADMIN_PASS=changeme npx playwright test
 *
 * Mobile only:
 *   DEVICE_IP=192.168.1.100 npx playwright test --project=mobile-ios --project=mobile-android
 */

// Core's own port (80 on 2026.8+, 8123 before) — helpers/ha-url.ts, ADR-0038.
const baseURL = haBaseUrl();

export default defineConfig({
  testDir: './tests',

  // Tests are against a single device — run sequentially to avoid race conditions
  fullyParallel: false,
  workers: 1,

  retries: 1,
  // 300s per test: resetOnboarding waits up to 240s for HA Core to come back
  // after `docker restart homeassistant` (iHost cold-start ~90-120s, sometimes
  // worse under load). Leaves 60s headroom for the actual assertions.
  timeout: 300_000,

  reporter: [
    ['list'],
    ['html', { open: 'never', outputFolder: 'playwright-report' }],
    ['json', { outputFile: 'test-results/results.json' }],
  ],

  use: {
    baseURL,
    navigationTimeout: 30_000,
    actionTimeout: 10_000,
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },

  projects: [
    // Desktop baseline — ensures functionality before mobile-specific checks
    {
      name: 'desktop',
      use: { ...devices['Desktop Chrome'] },
    },

    // iPhone 12 — primary mobile target (iOS Safari viewport, 390×844)
    {
      name: 'mobile-ios',
      use: { ...devices['iPhone 12'] },
    },

    // Pixel 5 — Android Chrome viewport (393×851)
    {
      name: 'mobile-android',
      use: { ...devices['Pixel 5'] },
    },
  ],
});
