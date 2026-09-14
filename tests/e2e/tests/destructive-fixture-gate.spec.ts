/**
 * The destructive fixtures must refuse to run without an explicit opt-in.
 *
 * Paid for on 2026-09-14: `pin-verification.spec.ts` calls `resetOnboarding()`
 * — which overwrites the wizard state file and restarts HA Core — in four
 * tests, gated only on `!pinRequired` / `!DEVICE_PIN`. Neither of those is an
 * opt-in for destruction. A routine regression run therefore reset the
 * onboarding state of a canary somebody was actively pairing devices on.
 *
 * `onboarding.spec.ts` and `telemetry-consent.spec.ts` DO gate on
 * RESET_ONBOARDING — so the convention existed and one spec simply did not
 * follow it. A convention that a spec can forget is a note, not a control, so
 * the gate now lives in the FIXTURE: every present and future caller inherits
 * it and no spec can opt out by omission.
 *
 * Both directions are asserted here (a gate that can only ever fire teaches
 * people to ignore it):
 *   - must-flag:     no opt-in  -> refuses, naming RESET_ONBOARDING
 *   - must-not-flag: opt-in set -> proceeds past the gate to the real work
 *
 * Neither case can touch a device: DEVICE_IP is cleared first, so even an
 * ungated fixture fails at `sshCmd` instead of resetting real hardware.
 */
import { expect } from '@playwright/test';
import { test } from '../fixtures/device';

function withEnv(overrides: Record<string, string | undefined>, fn: () => void) {
  const saved: Record<string, string | undefined> = {};
  for (const k of Object.keys(overrides)) {
    saved[k] = process.env[k];
    if (overrides[k] === undefined) delete process.env[k];
    else process.env[k] = overrides[k] as string;
  }
  try {
    fn();
  } finally {
    for (const k of Object.keys(saved)) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k] as string;
    }
  }
}

test.describe('destructive fixtures refuse to run without the opt-in', () => {
  test('resetOnboarding() refuses when RESET_ONBOARDING is not set', ({ resetOnboarding }) => {
    withEnv({ RESET_ONBOARDING: undefined, DEVICE_IP: undefined }, () => {
      // The message must name the variable — an error nobody can act on is
      // how a clear failure turns into "the harness is flaky".
      expect(() => resetOnboarding()).toThrow(/RESET_ONBOARDING/);
    });
  });

  test('resetOnboarding() proceeds past the gate when RESET_ONBOARDING is set', ({ resetOnboarding }) => {
    withEnv({ RESET_ONBOARDING: '1', DEVICE_IP: undefined }, () => {
      // Opted in, so the gate must let it through — it then fails on the next
      // real precondition. If this ever throws about RESET_ONBOARDING, the
      // gate has become unconditional and the suite can no longer run at all.
      expect(() => resetOnboarding()).toThrow(/DEVICE_IP not set/);
    });
  });
});
