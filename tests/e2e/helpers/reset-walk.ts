/**
 * Static judgement over a spec that resets the onboarding wizard and walks it.
 *
 * Onboarding >= 2.12.11 (Odoo #1704): POST /api/greenautarky_site/reset also
 * clears pin_verified and the consents. A spec that resets and then walks the
 * wizard therefore has to enter the PIN, tick GDPR and answer telemetry, in
 * that order, and must not swallow a failed reset. This returns the list of
 * problems (empty = fine) so the gate spec can prove it red and green with no
 * device.
 */
export function resetWalkProblems(src: string): string[] {
  const problems: string[] = [];
  const at = (needle: string | RegExp): number => {
    if (typeof needle === 'string') return src.indexOf(needle);
    const m = needle.exec(src);
    return m ? m.index : -1;
  };

  const reset = at('/api/greenautarky_site/reset');
  if (reset < 0) problems.push('does not call /api/greenautarky_site/reset');
  if (src.includes('greenautarky_onboarding/reset')) problems.push('uses the dead /api/greenautarky_onboarding/reset');
  if (/\/reset[^\n]*\|\|\s*true/.test(src)) problems.push('swallows a failed reset (|| true)');
  if (!/status[^\n]*\)\.toBe\(200\)/.test(src)) problems.push('does not assert the reset answered 200');

  const pin = at(/ga-setup-pin input'\)[^\n]*\n?[^\n]*\.fill\(\s*DEVICE_PIN/);
  const pinFill = pin >= 0 ? pin : at(/\.fill\(\s*DEVICE_PIN/);
  const gdpr = at(/ga-setup-gdpr ha-checkbox/);
  const telem = at(/toContain\('telemetry'\)/);
  if (pinFill < 0) problems.push('never enters the PIN (DEVICE_PIN) after the reset');
  if (gdpr < 0) problems.push('never ticks the GDPR checkbox');
  if (telem < 0) problems.push('never asserts the telemetry step was answered');
  if (pinFill >= 0 && reset >= 0 && pinFill < reset) problems.push('PIN entered before the reset');
  if (pinFill >= 0 && gdpr >= 0 && gdpr < pinFill) problems.push('GDPR ticked before the PIN');
  if (gdpr >= 0 && telem >= 0 && telem < gdpr) problems.push('telemetry answered before GDPR');
  if (/fill\(\s*['"`]\d{6}['"`]\s*\)/.test(src)) problems.push('hard-codes a PIN literal');
  return problems;
}
