import { execSync } from 'child_process';

/**
 * Device connection constants — consumed by test specs.
 *
 * Mirrors the pattern from tests/e2e/fixtures/device.ts.
 * All values are read from environment variables so the same test files work
 * locally, in CI, and with different devices without code changes.
 */

const DEFAULT_SSH_KEY =
  '~/.ssh/ha-ihost.pem';

export const DEVICE_IP = process.env.DEVICE_IP || 'homeassistant.local';
export const DEVICE_URL = process.env.DEVICE_URL || `http://${DEVICE_IP}:8123`;
export const SSH_KEY = process.env.SSH_KEY || DEFAULT_SSH_KEY;
export const SSH_PORT = process.env.SSH_PORT || '22222';

/**
 * Reset GA onboarding state via SSH and restart HA Core.
 *
 * DESTRUCTIVE — deletes /config/.storage/greenautarky_onboarding and restarts core.
 * Takes ~15-20s. Only call on dedicated test devices.
 *
 * Requires DEVICE_IP and SSH access (key at SSH_KEY, port SSH_PORT).
 */
export function resetOnboardingState(): void {
  if (!process.env.DEVICE_IP) {
    throw new Error('DEVICE_IP required for SSH-based onboarding reset');
  }

  const sshPrefix = [
    'ssh',
    '-o StrictHostKeyChecking=no',
    '-o UserKnownHostsFile=/dev/null',
    `-i ${SSH_KEY}`,
    `-p ${SSH_PORT}`,
    `root@${DEVICE_IP}`,
  ].join(' ');

  execSync(
    `${sshPrefix} "docker exec homeassistant rm -f /config/.storage/greenautarky_onboarding; ha core restart"`,
    { stdio: 'inherit', timeout: 30_000 },
  );
}
