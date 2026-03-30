import { test, expect } from "../fixtures/device";

/**
 * PIN Verification E2E Tests
 *
 * Tests the physical access PIN step in the onboarding wizard.
 * The PIN is a 6-digit code printed on the device sticker that must
 * be entered before proceeding to GDPR/account creation.
 *
 * Requires:
 *   - Device with GA onboarding not completed
 *   - PIN file on device (/mnt/data/supervisor/homeassistant/ga-onboarding-pin)
 *   - DEVICE_PIN env var with the correct PIN (for positive tests)
 *
 * If no PIN file exists on the device, tests are skipped (backward compat).
 */

const DEVICE_PIN = process.env.DEVICE_PIN || "";

test.describe("PIN verification (onboarding)", () => {
  let pinRequired = false;

  test.beforeAll(async ({ request, deviceUrl }) => {
    // Check if PIN is required on this device
    const res = await request.get(`${deviceUrl}/api/greenautarky_onboarding/status`);
    if (res.ok()) {
      const status = await res.json();
      pinRequired = status.pin_required === true && status.pin_verified !== true;
    }
  });

  test("status endpoint includes PIN fields", async ({ request, deviceUrl }) => {
    const res = await request.get(`${deviceUrl}/api/greenautarky_onboarding/status`);
    expect(res.ok()).toBeTruthy();
    const status = await res.json();
    expect(status).toHaveProperty("pin_required");
    expect(status).toHaveProperty("pin_verified");
    expect(typeof status.pin_required).toBe("boolean");
    expect(typeof status.pin_verified).toBe("boolean");
  });

  test("verify_pin rejects wrong PIN", async ({ request, deviceUrl }) => {
    test.skip(!pinRequired, "No PIN required on this device");

    const res = await request.post(`${deviceUrl}/api/greenautarky_onboarding/verify_pin`, {
      data: { pin: "000000" },
    });
    expect(res.status()).toBe(401);
    const body = await res.json();
    expect(body.status).toBe("error");
    expect(body.message).toContain("Invalid PIN");
  });

  test("verify_pin returns retry_after on repeated failures", async ({ request, deviceUrl }) => {
    test.skip(!pinRequired, "No PIN required on this device");

    // First wrong attempt (may already have attempts from previous test)
    await request.post(`${deviceUrl}/api/greenautarky_onboarding/verify_pin`, {
      data: { pin: "111111" },
    });

    // Second wrong attempt should have retry_after
    const res = await request.post(`${deviceUrl}/api/greenautarky_onboarding/verify_pin`, {
      data: { pin: "222222" },
    });
    const body = await res.json();
    // Either 401 with retry_after, or 429 if locked
    expect([401, 429]).toContain(res.status());
    if (res.status() === 401) {
      expect(body.retry_after).toBeGreaterThanOrEqual(0);
    }
    if (res.status() === 429) {
      expect(body.status).toBe("locked");
      expect(body.retry_after).toBeGreaterThan(0);
    }
  });

  test("verify_pin accepts correct PIN", async ({ request, deviceUrl }) => {
    test.skip(!pinRequired, "No PIN required on this device");
    test.skip(!DEVICE_PIN, "DEVICE_PIN env var not set");

    // Wait for any rate limit to expire
    const statusRes = await request.get(`${deviceUrl}/api/greenautarky_onboarding/status`);
    const status = await statusRes.json();
    if (status.pin_retry_after && status.pin_retry_after > 0) {
      test.skip(true, `Rate limited for ${status.pin_retry_after}s — run later`);
    }

    const res = await request.post(`${deviceUrl}/api/greenautarky_onboarding/verify_pin`, {
      data: { pin: DEVICE_PIN },
    });
    expect(res.ok()).toBeTruthy();
    const body = await res.json();
    expect(body.status).toBe("ok");

    // Verify status reflects verification
    const afterRes = await request.get(`${deviceUrl}/api/greenautarky_onboarding/status`);
    const afterStatus = await afterRes.json();
    expect(afterStatus.pin_verified).toBe(true);
    expect(afterStatus.steps_done).toContain("pin");
  });

  test("verify_pin is idempotent after success", async ({ request, deviceUrl }) => {
    test.skip(!pinRequired, "No PIN required on this device");
    test.skip(!DEVICE_PIN, "DEVICE_PIN env var not set");

    // If already verified (from previous test), should return ok
    const statusRes = await request.get(`${deviceUrl}/api/greenautarky_onboarding/status`);
    const status = await statusRes.json();
    test.skip(!status.pin_verified, "PIN not yet verified");

    const res = await request.post(`${deviceUrl}/api/greenautarky_onboarding/verify_pin`, {
      data: { pin: DEVICE_PIN },
    });
    expect(res.ok()).toBeTruthy();
    const body = await res.json();
    expect(body.status).toBe("ok");
  });

  test("GDPR endpoint blocked before PIN verification", async ({ request, deviceUrl }) => {
    test.skip(!pinRequired, "No PIN required on this device");

    // Only test if PIN is NOT yet verified
    const statusRes = await request.get(`${deviceUrl}/api/greenautarky_onboarding/status`);
    const status = await statusRes.json();
    test.skip(status.pin_verified === true, "PIN already verified");

    const res = await request.post(`${deviceUrl}/api/greenautarky_onboarding/gdpr`, {
      data: { accepted: true },
    });
    expect(res.status()).toBe(403);
    const body = await res.json();
    expect(body.error).toContain("PIN");
  });

  test("PIN step visible in wizard when required", async ({ page, deviceUrl }) => {
    test.skip(!pinRequired, "No PIN required on this device");

    // Navigate to onboarding page
    await page.goto(`${deviceUrl}/greenautarky-setup.html`);
    await page.waitForLoadState("networkidle");

    // Click through welcome step
    const startButton = page.locator("ha-button.start, mwc-button");
    if (await startButton.isVisible({ timeout: 5000 })) {
      await startButton.click();
    }

    // PIN step should appear
    const pinInput = page.locator("ga-setup-pin");
    await expect(pinInput).toBeVisible({ timeout: 10000 });
  });

  test("QR auto-inject: PIN from URL parameter auto-submitted", async ({ page, deviceUrl }) => {
    test.skip(!pinRequired, "No PIN required on this device");
    test.skip(!DEVICE_PIN, "DEVICE_PIN env var not set");

    // Simulate QR code scan: open setup page with ?pin= parameter
    await page.goto(`${deviceUrl}/greenautarky-setup.html?pin=${DEVICE_PIN}&device=KIB-SON-TEST`);
    await page.waitForLoadState("networkidle");

    // Click through welcome step
    const startButton = page.locator("ha-button.start, mwc-button");
    if (await startButton.isVisible({ timeout: 5000 })) {
      await startButton.click();
    }

    // PIN step should auto-submit — GDPR step should appear without manual PIN entry
    const gdprStep = page.locator("ga-setup-gdpr");
    await expect(gdprStep).toBeVisible({ timeout: 10000 });

    // URL should be cleaned (no ?pin= in address bar)
    expect(page.url()).not.toContain("pin=");
  });

  test("QR auto-inject: wrong PIN from URL falls back to manual entry", async ({ page, deviceUrl }) => {
    test.skip(!pinRequired, "No PIN required on this device");

    // Simulate QR code with wrong PIN
    await page.goto(`${deviceUrl}/greenautarky-setup.html?pin=000000`);
    await page.waitForLoadState("networkidle");

    // Click through welcome step
    const startButton = page.locator("ha-button.start, mwc-button");
    if (await startButton.isVisible({ timeout: 5000 })) {
      await startButton.click();
    }

    // PIN step should show error and manual input (auto-submit failed)
    const pinComponent = page.locator("ga-setup-pin");
    await expect(pinComponent).toBeVisible({ timeout: 10000 });

    // Error message should be visible
    const error = page.locator("ga-setup-pin .error");
    await expect(error).toBeVisible({ timeout: 5000 });
  });

  test("QR auto-inject: no PIN in URL shows manual entry", async ({ page, deviceUrl }) => {
    test.skip(!pinRequired, "No PIN required on this device");

    // Open setup page without ?pin= parameter
    await page.goto(`${deviceUrl}/greenautarky-setup.html`);
    await page.waitForLoadState("networkidle");

    // Click through welcome step
    const startButton = page.locator("ha-button.start, mwc-button");
    if (await startButton.isVisible({ timeout: 5000 })) {
      await startButton.click();
    }

    // PIN step should show manual input (no auto-submit)
    const pinComponent = page.locator("ga-setup-pin");
    await expect(pinComponent).toBeVisible({ timeout: 10000 });

    // Input field should be visible for manual entry
    const pinInput = page.locator("ga-setup-pin ha-textfield");
    await expect(pinInput).toBeVisible();
  });

  test("QR auto-inject: invalid PIN format in URL ignored", async ({ page, deviceUrl }) => {
    test.skip(!pinRequired, "No PIN required on this device");

    // Open with invalid PIN (not 6 digits)
    await page.goto(`${deviceUrl}/greenautarky-setup.html?pin=abc`);
    await page.waitForLoadState("networkidle");

    // Click through welcome step
    const startButton = page.locator("ha-button.start, mwc-button");
    if (await startButton.isVisible({ timeout: 5000 })) {
      await startButton.click();
    }

    // Should fall through to manual PIN entry (invalid format ignored)
    const pinComponent = page.locator("ga-setup-pin");
    await expect(pinComponent).toBeVisible({ timeout: 10000 });

    const pinInput = page.locator("ga-setup-pin ha-textfield");
    await expect(pinInput).toBeVisible();
  });

  test("PIN input accepts dash-formatted input", async ({ request, deviceUrl }) => {
    test.skip(!pinRequired, "No PIN required on this device");
    test.skip(!DEVICE_PIN, "DEVICE_PIN env var not set");

    // Send with dash format (e.g. "847-293")
    const dashPin = DEVICE_PIN.slice(0, 3) + "-" + DEVICE_PIN.slice(3);
    const res = await request.post(`${deviceUrl}/api/greenautarky_onboarding/verify_pin`, {
      data: { pin: dashPin },
    });
    // Should work — backend strips dashes
    const body = await res.json();
    expect(body.status).toBe("ok");
  });
});
