import { execSync } from 'child_process';

/**
 * Device connection constants — consumed by test specs.
 *
 * Supports two modes, selected via environment variables:
 *
 *   LOCAL MODE  (LOCAL_MODE=1)
 *     HA Core runs in Docker on the laptop.
 *     From emulator: http://10.0.2.2:8123  (10.0.2.2 = host gateway)
 *     From host:     http://localhost:8123
 *     Onboarding reset: docker exec ha-local (no SSH)
 *     Start HA:  tests/app/android/start-ha-local.sh
 *
 *   DEVICE MODE (default, DEVICE_IP=<ip>)
 *     HA Core runs on a real iHost device.
 *     From emulator: http://<DEVICE_IP>:8123
 *     From host:     http://<DEVICE_IP>:8123
 *     Onboarding reset: SSH to root@<DEVICE_IP>
 */

const DEFAULT_SSH_KEY = process.env.HOME + '/.ssh/ha-ihost.pem';

/** True when testing against local Docker HA Core (no physical iHost needed). */
export const LOCAL_MODE = process.env.LOCAL_MODE === '1';

/**
 * IP used by the EMULATOR to reach HA.
 *   LOCAL_MODE  → 10.0.2.2  (Android emulator gateway to host)
 *   DEVICE_MODE → DEVICE_IP (real iHost on the network)
 */
export const DEVICE_IP = LOCAL_MODE
  ? '10.0.2.2'
  : (process.env.DEVICE_IP || 'homeassistant.local');

/**
 * Full HA URL as seen by the emulator.
 */
export const DEVICE_URL =
  process.env.DEVICE_URL ||
  `http://${DEVICE_IP}:${process.env.HA_PORT || '8123'}`;

/**
 * Full HA URL as seen by the HOST (used for API calls in helpers).
 * In local mode this is localhost, in device mode it's the same as DEVICE_URL.
 */
export const HOST_URL = LOCAL_MODE
  ? `http://localhost:${process.env.HA_PORT || '8123'}`
  : DEVICE_URL;

export const SSH_KEY = process.env.SSH_KEY || DEFAULT_SSH_KEY;
export const SSH_PORT = process.env.SSH_PORT || '22222';

/** Docker container name for local HA Core (only used in LOCAL_MODE). */
const LOCAL_CONTAINER = process.env.HA_CONTAINER || 'ha-local';

/**
 * Reset GA onboarding state and restart HA Core.
 *
 * DESTRUCTIVE — deletes /config/.storage/greenautarky_onboarding and restarts.
 * Takes ~15-20s. Only call on dedicated test devices.
 *
 * LOCAL_MODE:  docker exec on host (no SSH needed)
 * DEVICE_MODE: SSH to root@DEVICE_IP
 */
export function resetOnboardingState(): void {
  if (LOCAL_MODE) {
    // Local Docker: run docker exec directly on the host
    execSync(
      `docker exec ${LOCAL_CONTAINER} rm -f /config/.storage/greenautarky_onboarding` +
      ` && docker restart ${LOCAL_CONTAINER}`,
      { stdio: 'inherit', timeout: 30_000 },
    );
    return;
  }

  if (!process.env.DEVICE_IP) {
    throw new Error('DEVICE_IP required for SSH-based onboarding reset (or set LOCAL_MODE=1)');
  }

  const sshPrefix = [
    'ssh',
    '-o StrictHostKeyChecking=no',
    '-o UserKnownHostsFile=/dev/null',
    `-i ${SSH_KEY}`,
    `-p ${SSH_PORT}`,
    `root@${process.env.DEVICE_IP}`,
  ].join(' ');

  execSync(
    `${sshPrefix} "docker exec homeassistant rm -f /config/.storage/greenautarky_onboarding; ha core restart"`,
    { stdio: 'inherit', timeout: 30_000 },
  );
}
