import type { Browser } from 'webdriverio';

/**
 * HA Companion app interaction helpers.
 *
 * The HA Companion app has two UI layers:
 *   1. Native Android UI  — server setup, permission dialogs (interact via UiSelector)
 *   2. WebView            — all HA web pages rendered in Chromium (interact via CSS/JS)
 *
 * Tests must switch between contexts using switchToWebView() / switchToNative().
 *
 * WebView automation REQUIRES a debug/debuggable APK:
 *   - android:debuggable="true" in AndroidManifest.xml
 *   - WebView.setWebContentsDebuggingEnabled(true) in app code
 *
 * The official release APK (Google Play / GitHub releases) does NOT have these.
 * Use a debug build from home-assistant/android GitHub Actions, or build locally:
 *   ./gradlew assembleFullDebug
 */

/** Known package names for the HA Companion app variants. */
export const APP_PACKAGE = {
  full: 'io.homeassistant.companion.android',
  debug: 'io.homeassistant.companion.android.debug',
  minimal: 'io.homeassistant.companion.android.minimal',
} as const;

/**
 * Switch WebDriver context to the HA Companion app's WebView.
 *
 * Polls for up to 20s for a WEBVIEW_* context to appear — the app needs
 * time to load the HA page before the WebView is registered with Chromedriver.
 *
 * Throws if no WebView is found (likely a non-debuggable APK).
 */
export async function switchToWebView(driver: Browser): Promise<void> {
  const deadline = Date.now() + 20_000;

  while (Date.now() < deadline) {
    const contexts = (await driver.getContexts()) as string[];
    const webview = contexts.find(c => c.startsWith('WEBVIEW'));

    if (webview) {
      await driver.switchContext(webview);
      return;
    }

    await driver.pause(1_000);
  }

  const contexts = (await driver.getContexts()) as string[];
  throw new Error(
    `No WebView context found after 20s.\n` +
      `Available contexts: ${contexts.join(', ')}\n\n` +
      `This usually means the APK is not debuggable.\n` +
      `Use a debug build (see tests/app/android/setup.sh for instructions).`,
  );
}

/** Switch back to the native Android UI context. */
export async function switchToNative(driver: Browser): Promise<void> {
  await driver.switchContext('NATIVE_APP');
}

/**
 * Add a new HA server in the Companion app's native "Add Server" UI.
 *
 * Flow:  Welcome screen → Add Server → enter URL → Connect
 *
 * Element selectors are based on HA Companion v2024.x. If the app updates its
 * native UI, update these selectors by inspecting with:
 *   adb exec-out uiautomator dump /dev/tty
 */
export async function addServer(driver: Browser, serverUrl: string): Promise<void> {
  // Dismiss any permission or notification prompts
  try {
    const skip = await driver.$('android=new UiSelector().textMatches("(?i)skip|not now|dismiss")');
    if (await skip.isDisplayed()) await skip.click();
  } catch {
    // No prompt present
  }

  // Click "Add Server" / "Get Started" on welcome screen
  const addBtn = await driver.$(
    'android=new UiSelector().textMatches("(?i)add.server|get.started")',
  );
  await addBtn.waitForDisplayed({ timeout: 15_000 });
  await addBtn.click();

  // Enter the server URL
  const urlInput = await driver.$('android=new UiSelector().className("android.widget.EditText")');
  await urlInput.waitForDisplayed({ timeout: 10_000 });
  await urlInput.clearValue();
  await urlInput.setValue(serverUrl);

  // Tap the Connect / Next button (or fall back to keyboard Enter)
  try {
    const nextBtn = await driver.$(
      'android=new UiSelector().textMatches("(?i)next|connect|continue")',
    );
    if (await nextBtn.isDisplayed()) {
      await nextBtn.click();
      return;
    }
  } catch {
    // Fall through
  }

  await driver.pressKeyCode(66); // KEYCODE_ENTER
}

/**
 * Poll HA's /api/ endpoint until it responds with 200 or 401.
 * Call before launching tests to confirm the device is accepting connections.
 */
export async function waitForHA(hassUrl: string, timeoutMs = 60_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${hassUrl}/api/`, {
        signal: AbortSignal.timeout(5_000),
      });
      if (res.status === 200 || res.status === 401) return;
    } catch {
      // Not ready yet
    }
    await new Promise(r => setTimeout(r, 2_000));
  }

  throw new Error(`HA did not become ready at ${hassUrl} within ${timeoutMs / 1000}s`);
}

/** Return the URL currently loaded in the WebView (runs document.location.href). */
export async function getWebViewUrl(driver: Browser): Promise<string> {
  return (await driver.execute(() => document.location.href)) as string;
}

/**
 * Log in to HA from within the WebView using admin credentials.
 *
 * Call after switchToWebView() when the app is showing the HA auth page.
 * Waits for the redirect away from /auth/ to confirm login succeeded.
 */
export async function loginInWebView(driver: Browser): Promise<void> {
  const user = process.env.HA_ADMIN_USER || 'admin';
  const pass = process.env.HA_ADMIN_PASS;
  if (!pass) throw new Error('HA_ADMIN_PASS required for loginInWebView');

  const usernameInput = await driver.$('#username');
  await usernameInput.waitForDisplayed({ timeout: 10_000 });
  await usernameInput.setValue(user);

  const passwordInput = await driver.$('#password');
  await passwordInput.setValue(pass);

  const submitBtn = await driver.$('mwc-button[raised]');
  await submitBtn.click();

  // Wait for redirect away from the auth page
  await driver.waitUntil(
    async () => !(await getWebViewUrl(driver)).includes('/auth/'),
    { timeout: 20_000, timeoutMsg: 'Login did not redirect — check credentials' },
  );
}
