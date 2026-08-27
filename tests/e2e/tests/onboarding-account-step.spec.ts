import type { APIRequestContext } from '@playwright/test';
import { randomUUID } from 'crypto';

import { test, expect, sshCmd } from '../fixtures/device';
import { getGAOnboardingStatus } from '../helpers/ha-api';

/**
 * The account step has to survive being pressed twice.
 *
 * It did not. On a bench device on 2026-08-26 the wizard sat at
 * `completed: false` with `account` already in `steps_done`, and every further
 * press of "Konto erstellen" answered
 *
 *     400  {"message":"Username already exists"}
 *
 * while leaving another orphaned user behind — FIVE presses produced THIRTEEN
 * users named "resident", exactly one of which could log in. The device was
 * fully provisioned, every device check was green, and nobody could finish
 * onboarding. A dropped connection while submitting the form is enough to
 * reach that state, and there is no way out of it from the UI.
 *
 * Nothing tested it at any layer. The two existing onboarding specs walk up to
 * the account form and stop; `create_user` appears in no other test in this
 * repo. That is why this file asserts the API contract rather than adding
 * another click-through: the contract is what broke, and it broke in a way a
 * screenshot cannot see — the response and the auth store disagreed.
 *
 * THREE THINGS ARE ASSERTED, and two of them were red on the shipped component:
 *
 *   1. a first submit creates the account                     (positive control)
 *   2. the SAME submit again succeeds and creates NOTHING NEW (the defect)
 *   3. the same username with a WRONG password is REFUSED     (the security half)
 *
 * (3) is not decoration. Making (2) work means handing out an auth_code for an
 * account the caller merely named; without a password check the retry fix would
 * have traded a dead end for a way in — anyone past the physical PIN could sign
 * in as an already-onboarded resident by typing their address. (2) and (3) have
 * to be asserted together, or the fix for one silently undoes the other.
 *
 * User counts are read from the device's auth store over SSH rather than from
 * the HTTP response, because "200 and wreckage" is precisely the shape of the
 * bug: the endpoint answered about itself, not about what it left behind.
 *
 * EACH TEST MINTS AND CLEANS UP ITS OWN ACCOUNT. That is not tidiness, it is
 * the difference between a test and a decoration: the first version of this
 * file derived one username from `process.pid` and shared it across the three
 * tests. Playwright restarts the worker process after a failure, so the pid
 * changed mid-run and test (3) ran against a username that did not exist yet —
 * it passed against a component that had never implemented the check. A test
 * whose subject can silently change is worse than no test, because it reports.
 *
 * Requires DEVICE_IP (SSH) and a device whose onboarding wizard has not been
 * completed yet.
 *
 * Red proof, bench device, 2026-08-27, component 2.3.0 (the shipped version):
 *   (1) passed   (2) failed: 400 "Username already exists"   (3) failed
 * Green against 2.4.0 with the same three assertions.
 */

const AUTH_STORE = '/mnt/data/supervisor/homeassistant/.storage/auth';

/** The name every probe account carries, so cleanup can find them all. */
const PROBE_NAME = 'e2e account step probe';
const PROBE_PREFIX = 'e2e-account-step-';

/**
 * The throwaway secret this suite signs its probe accounts with.
 *
 * Generated per run rather than written down. A literal here would be a
 * credential-shaped string in a PUBLIC repository — worthless as a secret, but
 * indistinguishable from a real one to anyone reading the diff, and to the
 * disclosure gate. Generating it also means two concurrent runs cannot end up
 * sharing one.
 */
const PROBE_SECRET = `Ee2!${randomUUID()}`;

let mintCounter = 0;

/**
 * A username no human will have, unique within this run AND across runs.
 *
 * Uniqueness must not depend on anything Playwright can reset under us — see
 * the worker-restart note above. A timestamp plus a local counter survives a
 * worker restart, because a restarted worker gets a later timestamp rather
 * than the same one.
 */
function mintUsername(): string {
  mintCounter += 1;
  return `${PROBE_PREFIX}${Date.now()}-${mintCounter}@invalid`;
}

/** How many users the device's auth store holds, as the device sees it. */
function userCount(): number {
  return Number(sshCmd(`jq ".data.users|length" ${AUTH_STORE}`));
}

/** True if the auth store knows a credential for `username`. */
function credentialExists(username: string): boolean {
  const n = sshCmd(
    `jq "[.data.credentials[]|select(.data.username==\\"${username}\\")]|length" ${AUTH_STORE}`,
  );
  return Number(n) > 0;
}

/**
 * Remove every probe account this suite has ever left on the device.
 *
 * HA ships no CLI for deleting a user, so this edits the auth store with Core
 * stopped — the only way to write it without Core overwriting the file on its
 * next flush. Restarting Core afterwards is not optional: a running Core keeps
 * the auth provider in memory and would write the deleted users straight back.
 *
 * It deletes by PREFIX, not by the username of this run, so a run that died
 * before its cleanup does not leave accounts on a device forever.
 *
 * The script is shipped base64-encoded rather than interpolated into the SSH
 * command line. A jq filter contains parentheses, quotes and pipes, and it
 * passes through THREE shells on the way to the device — the readable version
 * of this died with `sh: Syntax error: "(" unexpected` and left the probe
 * account behind while the suite reported green.
 */
function purgeProbeAccounts(): void {
  const script = [
    'set -e',
    'ha core stop',
    `jq '.data.users |= map(select(.name != "${PROBE_NAME}"))` +
      ` | .data.credentials |= map(select(.data.username | startswith("${PROBE_PREFIX}") | not))'` +
      ` ${AUTH_STORE} > /tmp/auth.probe-clean`,
    `cat /tmp/auth.probe-clean > ${AUTH_STORE}`,
    'rm -f /tmp/auth.probe-clean',
    'ha core start',
  ].join('\n');
  const b64 = Buffer.from(script, 'utf-8').toString('base64');
  sshCmd(`echo ${b64} | base64 -d > /tmp/probe-clean.sh && sh /tmp/probe-clean.sh`);
}

/**
 * POST the account step exactly as the wizard's form does.
 *
 * One builder rather than four inline bodies: the endpoint's field names live
 * in a single place, so a rename is one edit and the tests below read as what
 * they assert rather than as four copies of a payload.
 */
function submitAccountStep(
  request: APIRequestContext,
  deviceUrl: string,
  username: string,
  secret: string,
) {
  return request.post(`${deviceUrl}/api/greenautarky_site/create_user`, {
    data: { client_id: `${deviceUrl}/`, name: PROBE_NAME, username, password: secret },
  });
}

test.describe('Onboarding account step — pressing it twice is not a dead end', () => {
  test.beforeAll(() => {
    if (!process.env.DEVICE_IP) {
      test.skip(true, 'DEVICE_IP required — the auth store is read over SSH');
    }
  });

  test.beforeEach(async ({ deviceUrl }) => {
    const status = await getGAOnboardingStatus(deviceUrl);
    if (status.completed) {
      test.skip(
        true,
        'Onboarding is already completed — /create_user answers 403 by design. ' +
          'Reset the wizard (RESET_ONBOARDING flow) to exercise this contract.',
      );
    }
    if ((status as { pin_verified?: boolean }).pin_verified === false) {
      test.skip(
        true,
        'The wizard PIN has not been verified on this device — /create_user is ' +
          'PIN-gated and would answer 403 for reasons unrelated to this contract.',
      );
    }
  });

  test.afterAll(() => {
    if (!process.env.DEVICE_IP) return;
    try {
      purgeProbeAccounts();
    } catch {
      // A leftover probe account is visible and harmless; failing the suite in
      // cleanup would hide the result the run actually produced.
    }
  });

  /**
   * The positive control. A check that can only ever go red teaches people to
   * ignore its colour, so prove the endpoint works at all before asserting how
   * it fails. This one passes on the broken component too — that is the point.
   */
  test('a first submit creates the account', async ({ request, deviceUrl }) => {
    const username = mintUsername();
    const before = userCount();

    const res = await submitAccountStep(request, deviceUrl, username, PROBE_SECRET);

    expect(res.status(), await res.text()).toBe(200);
    expect(await res.json()).toHaveProperty('auth_code');
    expect(userCount(), 'the submit must create exactly one user').toBe(before + 1);
    expect(credentialExists(username), 'the account must be able to log in').toBe(true);
  });

  /**
   * THE DEFECT. Same address, same password, second press — in ONE test, so
   * the account it resubmits is provably the account it just created.
   *
   * Before the fix this was 400 "Username already exists" AND userCount()+1 —
   * a dead end that also littered. Both halves are asserted: a 200 that still
   * creates an orphan is not a fix, it is the same bug with a nicer status.
   */
  test('the same submit again succeeds and creates nothing new', async ({
    request,
    deviceUrl,
  }) => {
    const username = mintUsername();

    const first = await submitAccountStep(request, deviceUrl, username, PROBE_SECRET);
    expect(first.status(), `precondition — the first submit must work: ${await first.text()}`)
      .toBe(200);
    const afterFirst = userCount();

    const second = await submitAccountStep(request, deviceUrl, username, PROBE_SECRET);

    expect(
      second.status(),
      `resubmitting the account step must not be a dead end — got ${second.status()}: ${await second.text()}`,
    ).toBe(200);
    expect(await second.json()).toHaveProperty('auth_code');
    expect(
      userCount(),
      'adopting an existing account must not leave another user behind',
    ).toBe(afterFirst);
  });

  /**
   * THE SECURITY HALF. Adopting an account means minting an auth_code for it,
   * so the password is what separates "the person retrying their own form"
   * from "anyone who got past the PIN and knows an address".
   */
  test('the same username with a wrong password is refused', async ({
    request,
    deviceUrl,
  }) => {
    const username = mintUsername();

    const first = await submitAccountStep(request, deviceUrl, username, PROBE_SECRET);
    expect(first.status(), `precondition — the account must exist: ${await first.text()}`)
      .toBe(200);
    const afterFirst = userCount();

    const wrong = await submitAccountStep(
      request,
      deviceUrl,
      username,
      `not-${PROBE_SECRET}`,
    );

    expect(
      wrong.status(),
      `an existing account must never be adopted without its password — got ${wrong.status()}: ${await wrong.text()}`,
    ).toBe(401);
    expect(await wrong.text()).not.toContain('auth_code');
    expect(userCount()).toBe(afterFirst);
  });
});
