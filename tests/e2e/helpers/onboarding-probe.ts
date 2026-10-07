/**
 * When `onboarding-account-step.spec.ts` may clean up after itself.
 *
 * Its cleanup is not free: HA has no CLI for deleting a user, so it stops Core,
 * edits the auth store and starts Core again. The first version ran that in
 * `afterAll` unconditionally — including on a device whose wizard was already
 * completed, where every test skips and nothing was ever created. It restarted
 * Core in the middle of a full run and the NEXT spec failed against a booting
 * Core (bench canary, rc8, 2026-10-07).
 *
 * So the decision is a function over data, proven by
 * `destructive-fixture-gate.spec.ts`: restart Core only when this suite sent
 * at least one account submit. Counted BEFORE the request goes out — a submit
 * that timed out may still have created the user, and that one must be purged.
 */
export type ProbeCleanup = 'no-device' | 'nothing-submitted' | 'purged';

export function cleanupProbeAccounts(opts: {
  deviceIp: string | undefined;
  submissions: number;
  purge: () => void;
}): ProbeCleanup {
  if (!opts.deviceIp) return 'no-device';
  if (!(opts.submissions > 0)) return 'nothing-submitted';
  opts.purge();
  return 'purged';
}
