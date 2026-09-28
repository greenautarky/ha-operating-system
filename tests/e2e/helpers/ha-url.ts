/**
 * Where Home Assistant Core answers on the device under test (ADR-0038).
 *
 * Core 2026.8+ serves on :80, older Core on :8123 — the fleet is mixed, so no
 * spec may hard-code either. The shell runners (run_e2e_tests.sh,
 * run-with-device-secrets.sh) ask the device's Supervisor once
 * (ga_tests/lib/ha_port.sh) and export DEVICE_URL, which always wins here.
 * Without it: DEVICE_IP (or homeassistant.local) on GA_HA_PORT, else on 80 —
 * the ADR default. 8123 is used only when someone says so.
 */
export function haBaseUrl(): string {
  if (process.env.DEVICE_URL) return process.env.DEVICE_URL.replace(/\/+$/, '');
  const host = process.env.DEVICE_IP || 'homeassistant.local';
  const port = process.env.GA_HA_PORT || '80';
  return port === '80' ? `http://${host}` : `http://${host}:${port}`;
}

/** The TCP port Core listens on, for commands run ON the device (curl localhost). */
export function haPort(): string {
  if (process.env.GA_HA_PORT) return process.env.GA_HA_PORT;
  const u = new URL(haBaseUrl());
  return u.port || (u.protocol === 'https:' ? '443' : '80');
}
