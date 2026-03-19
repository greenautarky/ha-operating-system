import { execSync, spawnSync } from 'child_process';

/**
 * Android Virtual Device lifecycle helpers.
 *
 * Used by run_app_tests.sh (via android/start-emulator.sh) and optionally
 * from test beforeAll hooks when managing the emulator inside the test run.
 */

const ANDROID_HOME =
  process.env.ANDROID_HOME || `${process.env.HOME}/Android/Sdk`;

const ADB = `${ANDROID_HOME}/platform-tools/adb`;
const EMULATOR = `${ANDROID_HOME}/emulator/emulator`;

/** Returns true if at least one emulator is connected and online via adb. */
export function isEmulatorRunning(): boolean {
  try {
    const out = execSync(`"${ADB}" devices 2>/dev/null`, { encoding: 'utf8' });
    return /emulator-\d+\s+device/.test(out);
  } catch {
    return false;
  }
}

/**
 * Launch the named AVD in headless mode (no audio, no window).
 * No-ops if an emulator is already running.
 */
export function startEmulator(avdName: string): void {
  if (isEmulatorRunning()) {
    console.log('[avd] emulator already running — skipping start');
    return;
  }

  console.log(`[avd] starting AVD: ${avdName}`);

  // Launch detached — the emulator process must outlive this node process
  const result = spawnSync(
    EMULATOR,
    [
      '-avd', avdName,
      '-no-audio',
      '-no-window',
      '-gpu', 'swiftshader_indirect',
      '-no-snapshot-save',
    ],
    { detached: true, stdio: 'ignore' },
  );

  if (result.error) {
    throw new Error(
      `Failed to launch emulator '${avdName}': ${result.error.message}\n` +
        `Check ANDROID_HOME (${ANDROID_HOME}) and AVD name.`,
    );
  }
}

/**
 * Block until the emulator's sys.boot_completed property is "1".
 * Polls every 3 seconds up to timeoutMs.
 */
export function waitForEmulatorBoot(timeoutMs = 120_000): void {
  const deadline = Date.now() + timeoutMs;
  console.log('[avd] waiting for emulator boot...');

  while (Date.now() < deadline) {
    try {
      const out = execSync(`"${ADB}" -e shell getprop sys.boot_completed 2>/dev/null`, {
        encoding: 'utf8',
        timeout: 5_000,
      });
      if (out.trim() === '1') {
        execSync('sleep 3'); // Extra settling time
        console.log('[avd] emulator ready');
        return;
      }
    } catch {
      // Emulator not ready yet
    }
    execSync('sleep 3');
  }

  throw new Error(`Emulator did not boot within ${timeoutMs / 1000}s`);
}

/** Send the emu kill command to the running emulator (best-effort). */
export function stopEmulator(): void {
  try {
    execSync(`"${ADB}" -e emu kill 2>/dev/null`, { timeout: 10_000 });
    console.log('[avd] emulator stopped');
  } catch {
    // Best-effort — don't fail tests on cleanup
  }
}
