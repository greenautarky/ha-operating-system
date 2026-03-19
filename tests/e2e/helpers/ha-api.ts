/**
 * HA REST API helpers for use in E2E tests.
 * All functions use raw fetch (no browser page) — safe to call from fixtures and beforeAll.
 */

export interface GAOnboardingStatus {
  completed: boolean;
  gdpr_accepted: boolean;
  steps_done: string[];
  consents?: Record<string, unknown>;
}

/**
 * Poll until HA Core is reachable and responding.
 * HA returns 401 (unauthenticated) when running but not yet logged in.
 * Returns as soon as it sees 200 or 401.
 *
 * @param hassUrl  Base URL, e.g. http://192.168.1.100:8123
 * @param timeoutMs  Max wait time in ms (default 60s)
 */
export async function waitForHA(hassUrl: string, timeoutMs = 60_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${hassUrl}/api/`, {
        signal: AbortSignal.timeout(4_000),
      });
      if (res.status === 200 || res.status === 401) return;
    } catch {
      // Connection refused or timeout — HA not ready yet
    }
    await new Promise(r => setTimeout(r, 2_000));
  }
  throw new Error(`HA did not become ready at ${hassUrl} within ${timeoutMs}ms`);
}

/**
 * Fetch the GA onboarding status.
 * This endpoint is unauthenticated by design (gated by completion check).
 */
export async function getGAOnboardingStatus(hassUrl: string): Promise<GAOnboardingStatus> {
  const res = await fetch(`${hassUrl}/api/greenautarky_onboarding/status`);
  if (!res.ok) {
    throw new Error(`Status endpoint returned ${res.status} — is HA Core running?`);
  }
  return res.json() as Promise<GAOnboardingStatus>;
}
