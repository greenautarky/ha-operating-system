/**
 * The reset-then-walk specs must follow onboarding 2.12.11 (Odoo #1704).
 *
 * must-pass: the LIVE telemetry-consent.spec.ts (read from disk, not a copy).
 * must-flag: mutations of it, one per rule, each proving that rule's check can
 * go red. No device, no browser, no network.
 */
import { expect, test } from '@playwright/test';
import { readFileSync } from 'fs';
import { join } from 'path';

import { resetWalkProblems } from '../helpers/reset-walk';

const LIVE = readFileSync(join(__dirname, 'telemetry-consent.spec.ts'), 'utf8');

test.describe('reset-then-walk specs enter the PIN after the reset', () => {
  test('the live telemetry-consent spec is clean', () => {
    expect(LIVE.length).toBeGreaterThan(1000); // coverage: we really read the file
    expect(resetWalkProblems(LIVE)).toEqual([]);
  });

  const mutants: Array<[string, (s: string) => string, RegExp]> = [
    ['PIN step removed', (s) => s.replace(/await pinInput\.fill\(DEVICE_PIN!\);/, ''), /never enters the PIN/],
    ['PIN literal', (s) => s.replace('fill(DEVICE_PIN!)', "fill('123456')"), /never enters the PIN|hard-codes/],
    ['GDPR tick removed', (s) => s.replace('ga-setup-gdpr ha-checkbox', 'ga-setup-gdpr x'), /GDPR/],
    ['telemetry answer removed', (s) => s.replace("toContain('telemetry')", 'toBeDefined()'), /telemetry step/],
    ['dead reset URL', (s) => s.replace('greenautarky_site/reset', 'greenautarky_onboarding/reset'), /dead|does not call/],
    ['reset failure swallowed', (s) => s.replace('/reset`, {', "/reset` || true, {"), /swallows/],
    ['reset status not asserted', (s) => s.replace('.toBe(200)', '.toBeDefined()'), /answered 200/],
  ];
  for (const [name, mutate, expected] of mutants) {
    test(`must flag: ${name}`, () => {
      const mutated = mutate(LIVE);
      expect(mutated, 'mutation must change the source').not.toBe(LIVE);
      const problems = resetWalkProblems(mutated);
      expect(problems.some((p) => expected.test(p)), `got: ${JSON.stringify(problems)}`).toBe(true);
    });
  }
});
