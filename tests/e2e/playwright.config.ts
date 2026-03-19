import { defineConfig, devices } from '@playwright/test';

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

const baseURL =
  process.env.DEVICE_URL ||
  (process.env.DEVICE_IP ? `http://${process.env.DEVICE_IP}:8123` : 'http://homeassistant.local:8123');

export default defineConfig({
  testDir: './tests',

  // Tests are against a single device — run sequentially to avoid race conditions
  fullyParallel: false,
  workers: 1,

  retries: 1,
  timeout: 60_000,

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
