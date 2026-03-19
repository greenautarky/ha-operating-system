import { test as base, expect } from '@playwright/test';
import { execSync } from 'child_process';

export interface DeviceFixtures {
  /** Base URL of the HA instance, e.g. http://192.168.1.100:8123 */
  deviceUrl: string;

  /**
   * Reset GA onboarding state on the device and restart HA Core.
   *
   * DESTRUCTIVE — deletes /config/.storage/greenautarky_onboarding and restarts core.
   * Requires DEVICE_IP and SSH access. Only use on dedicated test devices.
   *
   * Guarded by RESET_ONBOARDING=1 env var — tests skip if not set.
   */
  resetOnboarding: () => void;
}

export const test = base.extend<DeviceFixtures>({
  deviceUrl: async ({}, use) => {
    const ip = process.env.DEVICE_IP;
    const url =
      process.env.DEVICE_URL ||
      (ip ? `http://${ip}:8123` : 'http://homeassistant.local:8123');
    await use(url);
  },

  resetOnboarding: async ({}, use) => {
    const ip = process.env.DEVICE_IP;
    const key =
      process.env.SSH_KEY ||
      '~/.ssh/ha-ihost.pem';
    const port = process.env.SSH_PORT || '22222';

    await use(() => {
      if (!ip) throw new Error('DEVICE_IP not set — required for SSH-based onboarding reset');

      const sshPrefix = [
        'ssh',
        '-o StrictHostKeyChecking=no',
        '-o UserKnownHostsFile=/dev/null',
        `-i ${key}`,
        `-p ${port}`,
        `root@${ip}`,
      ].join(' ');

      // Delete GA onboarding state and restart HA Core
      execSync(
        `${sshPrefix} "docker exec homeassistant rm -f /config/.storage/greenautarky_onboarding; ha core restart"`,
        { timeout: 30_000 },
      );
    });
  },
});

export { expect };
