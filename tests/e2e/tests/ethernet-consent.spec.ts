import { test, expect } from "../fixtures/device";

test.describe("Ethernet consent (onboarding)", () => {
  test("ethernet consent API endpoint exists", async ({ request, deviceUrl }) => {
    const res = await request.post(`${deviceUrl}/api/greenautarky_onboarding/ethernet`, {
      data: { enable_ethernet: false },
    });
    // Should return 200 or 403 (if onboarding completed)
    expect([200, 403]).toContain(res.status());
  });
});
