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
   */
  resetOnboarding: () => void;
}

function sshCmd(cmd: string): string {
  const ip = process.env.DEVICE_IP;
  if (!ip) throw new Error('DEVICE_IP not set');
  const key =
    process.env.SSH_KEY ||
    process.env.HOME + '/Nextcloud2/GreenAutarky/security_store/HomeassistantGreen0.pem';
  const port = process.env.SSH_PORT || '22222';
  const sshPrefix = `ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${key} -p ${port} root@${ip}`;
  return execSync(`${sshPrefix} '${cmd}'`, { timeout: 60_000 }).toString().trim();
}

export const test = base.extend<DeviceFixtures>({
  deviceUrl: async ({}, use) => {
    const ip = process.env.DEVICE_IP;
    const url =
      process.env.DEVICE_URL ||
      (ip ? `http://${ip}:8123` : 'http://homeassistant.local:8123');
    await use(url);
  },

  resetOnboarding: async ({ deviceUrl }, use) => {
    await use(() => {
      // Delete state file and restart HA Core
      sshCmd('rm -f /mnt/data/supervisor/homeassistant/.storage/greenautarky_onboarding && docker restart homeassistant');

      // Wait for HA to come back up (poll status endpoint)
      const maxWait = 60_000;
      const start = Date.now();
      while (Date.now() - start < maxWait) {
        try {
          const res = execSync(
            `curl -sf --connect-timeout 5 ${deviceUrl}/api/greenautarky_onboarding/status`,
            { timeout: 10_000 },
          ).toString();
          if (res.includes('"pin_required"')) return; // HA is back
        } catch {
          // not ready yet
        }
        execSync('sleep 3');
      }
      throw new Error('HA Core did not come back after onboarding reset');
    });
  },
});

export { expect };
