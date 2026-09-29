/**
 * The reverse-proxy trust Home Assistant Core is RUNNING — not the YAML file.
 *
 * Core 2026.8 imports a YAML `http:` block once, at the first start, then
 * ignores it. On a fresh flash that start comes before ga_manager writes
 * ga_packages/ga_http.yaml, so the file can be perfect while Core trusts no
 * proxy at all. Same question as config_verify CFG-32..34 (ADR-0038), asked the
 * same way: `http/config` over the Supervisor websocket, from inside the
 * ga_manager container (the one holding a SUPERVISOR_TOKEN), with the SAME
 * query script — ga_tests/config_verify/http_config_query.py.
 *
 * Core < 2026.8 (positively known old) still reads YAML; the caller then keeps
 * the file checks. Unknown version = the new path (ADR default).
 */
import { execSync } from 'child_process';
import { readFileSync } from 'fs';
import { resolve } from 'path';
import { sshJump } from '../fixtures/device';

const QUERY = resolve(__dirname, '..', '..', 'ga_tests', 'config_verify', 'http_config_query.py');

export type HttpTrust =
  | { era: 'yaml'; coreVersion: string }
  | {
      era: 'storage';
      coreVersion: string;
      activeConfigType: string;
      pending: unknown;
      running: { use_x_forwarded_for?: boolean; trusted_proxies?: string[] } | null;
    };

function ssh(): string {
  const ip = process.env.DEVICE_IP;
  if (!ip) throw new Error('DEVICE_IP not set');
  const key =
    process.env.SSH_KEY ||
    process.env.HOME + '/Nextcloud2/GreenAutarky/security_store/HomeassistantGreen0.pem';
  const port = process.env.SSH_PORT || '22222';
  return `ssh ${sshJump()}-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${key} -p ${port} root@${ip}`;
}

/** true = Core >= 2026.8, false = known older, null = unparseable. */
export function isStorageEra(version: string): boolean | null {
  const m = /^(\d{4})\.(\d{1,2})(?:\D|$)/.exec(version || '');
  if (!m) return null;
  const [maj, min] = [Number(m[1]), Number(m[2])];
  return maj > 2026 || (maj === 2026 && min >= 8);
}

export function readHttpTrust(): HttpTrust {
  const info = JSON.parse(
    execSync(`${ssh()} 'ha core info --raw-json --no-progress'`, { timeout: 30_000 }).toString(),
  );
  const coreVersion = String(info?.data?.version ?? '');
  if (isStorageEra(coreVersion) === false) return { era: 'yaml', coreVersion };

  const out = execSync(
    `${ssh()} 'docker exec -i $(docker ps --filter name=ga_manager --format "{{.Names}}" | head -1) python3 -'`,
    { input: readFileSync(QUERY), timeout: 60_000 },
  ).toString();
  const msg = JSON.parse(out);
  if (typeof msg.error === 'string') throw new Error(`http/config not asked: ${msg.error}`);
  if (!msg.success) throw new Error(`http/config refused: ${JSON.stringify(msg.error)}`);
  const r = msg.result;
  const t = String(r.active_config_type);
  const running = t === 'pending' ? r.pending : t === 'stable' ? r.stable : r.default;
  return { era: 'storage', coreVersion, activeConfigType: t, pending: r.pending, running };
}

/** Core stores each proxy as a network: a bare address and its /32 are the same entry. */
export function trustsProxy(list: unknown, addr: string): boolean {
  return Array.isArray(list) && list.map(String).some((p) => p === addr || p === `${addr}/32`);
}

/** The GA services address the OS publishes to /share (ga-publish-services). */
export function servicesAddress(): string {
  const raw = execSync(
    `${ssh()} 'cat /mnt/data/supervisor/share/ga-services.json 2>/dev/null || echo {}'`,
    { timeout: 15_000 },
  ).toString();
  try {
    return String(JSON.parse(raw).ga_services_ip ?? '');
  } catch {
    return '';
  }
}

/** The YAML Core < 2026.8 reads (configuration.yaml + ga_packages/). */
export function readHttpYaml(): string {
  return execSync(
    `${ssh()} 'cat /mnt/data/supervisor/homeassistant/configuration.yaml /mnt/data/supervisor/homeassistant/ga_packages/*.yaml 2>/dev/null'`,
    { timeout: 15_000 },
  ).toString();
}
