import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { expect, test } from '@playwright/test';
import { auditEditorialSlateScreen } from './helpers/editorial-slate-audit';
import { startServeFixture, type ServedEmulatorHandle } from './helpers/serve-fixture';

const ARTIFACT_DIR =
  process.env['RA8_M2_SCREENSHOT_DIR'] || path.resolve(process.cwd(), 'test-results', 'screenshots');

function saveM2Shot(page: import('@playwright/test').Page, name: string): Promise<Buffer> {
  fs.mkdirSync(ARTIFACT_DIR, { recursive: true });
  return page.screenshot({ path: path.join(ARTIFACT_DIR, name) });
}

function parseDiscoveryGdbPort(discoveryPath: string): number {
  const raw = fs.readFileSync(discoveryPath, 'utf8');
  for (const line of raw.split(/\r?\n/)) {
    const m = /^session\s+(\d+)\s+/.exec(line.trim());
    if (m?.[1]) return Number.parseInt(m[1], 10);
  }
  throw new Error(`Missing GDB session line in discovery file:\n${raw}`);
}

async function waitForDiscoveryFile(discoveryPath: string): Promise<number> {
  const deadline = Date.now() + 8000;
  while (Date.now() < deadline) {
    if (fs.existsSync(discoveryPath)) {
      const text = fs.readFileSync(discoveryPath, 'utf8');
      if (text.includes('session ')) return parseDiscoveryGdbPort(discoveryPath);
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`Timed out waiting for discovery file at ${discoveryPath}`);
}

function sendGdbStepOverTcp(port: number): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    const sock = net.createConnection({ host: '127.0.0.1', port });
    let buf = '';
    const timer = setTimeout(() => {
      sock.destroy();
      reject(new Error(`GDB step response timeout. Received: ${buf}`));
    }, 8000);
    sock.once('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
    sock.on('data', (chunk) => {
      buf += chunk.toString('utf8');
      const m = /\$([TW][^#]+)#([0-9a-fA-F]{2})/.exec(buf);
      if (m) {
        clearTimeout(timer);
        sock.write('+');
        sock.end();
        resolve(m[0]);
      }
    });
    sock.once('connect', () => {
      sock.write('+$s#73');
    });
  });
}

test.describe('Screen 02 (/connect), Saved Hosts, Observe Mode, & Multi-Client Sync', () => {
  let server: ServedEmulatorHandle | null = null;
  let tempHome: string | null = null;

  test.afterEach(async () => {
    if (server) {
      await server.stop();
      server = null;
    }
    if (tempHome && fs.existsSync(tempHome)) {
      fs.rmSync(tempHome, { recursive: true, force: true });
      tempHome = null;
    }
  });

  test('renders honest empty state at 1440x900 and 1280x720 with zero fake profiles', async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto('/connect');
    await expect(page.getByTestId('connect-live-empty')).toBeVisible();
    await expect(page.getByTestId('connect-saved-empty')).toBeVisible();
    await expect(page.getByTestId('connect-footer-hint')).toContainText('--discover');
    await auditEditorialSlateScreen(page, 'screen02-empty-1440');

    await page.setViewportSize({ width: 1280, height: 720 });
    await auditEditorialSlateScreen(page, 'screen02-empty-1280');
  });

  test('auto-opens SSH Tunnel + Auth drawers, saves/pins/removes host profiles', async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto('/connect');

    const urlInput = page.getByTestId('connect-url-input');
    await urlInput.fill('ssh://build@10.0.4.18:4568');
    await expect(page.getByTestId('connect-ssh-drawer')).toBeVisible();
    await expect(page.getByTestId('connect-ssh-command')).toContainText(
      'ssh -N -L 4567:127.0.0.1:4568 build@10.0.4.18'
    );

    await page.getByTestId('connect-auth-toggle').click();
    await expect(page.getByTestId('connect-auth-drawer')).toBeVisible();
    await page.getByTestId('connect-auth-mode').selectOption('token');
    await page.getByTestId('connect-profile-name-input').fill('ci-runner-arm-02');
    await auditEditorialSlateScreen(page, 'screen02-ssh-auth');
    await saveM2Shot(page, 'm2_02_ssh_tunnel_auth.png');

    await page.getByTestId('connect-save-ssh-btn').click();
    await expect(page.getByTestId('connect-card')).toContainText('ci-runner-arm-02');

    // Also test pin & kebab remove
    const firstPin = page.locator('[data-testid^="saved-host-pin-"]').first();
    await firstPin.click();
    await page.locator('[data-testid^="saved-host-menu-"]').first().click();
    await page.locator('[data-testid^="saved-host-remove-"]').first().click();
    await expect(page.getByTestId('connect-saved-empty')).toBeVisible();
  });

  test('probes live serve --discover, attaches in Observe mode, and auto-syncs external GDB step', async ({ page }) => {
    tempHome = fs.mkdtempSync(path.join(os.tmpdir(), 'ra8-m2-e2e-'));
    server = await startServeFixture(path.join('tests', 'fixtures', 'gpio', 'blink.elf'), ['--discover'], {
      HOME: tempHome,
      USERPROFILE: tempHome,
    });
    const discoveryPath = path.join(tempHome, '.config', 'ra8_emulator', 'discovery');
    const gdbPort = await waitForDiscoveryFile(discoveryPath);

    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto('/connect');

    // Save two realistic remote host profiles via UI so Connect card shows populated SAVED HOSTS cleanly
    await page.getByTestId('connect-auth-toggle').click();
    await page.getByTestId('connect-auth-mode').selectOption('token');
    await page.getByTestId('connect-profile-name-input').fill('hil-bench-04.local');
    await page.getByTestId('connect-url-input').fill('wss://hil-rack-04.lab:8443/rpc');
    await page.getByTestId('connect-save-profile-btn').click();

    await page.getByTestId('connect-profile-name-input').fill('ci-runner-arm-02');
    await page.getByTestId('connect-auth-mode').selectOption('none');
    await page.getByTestId('connect-url-input').fill('ssh://build@10.0.4.18:4568');
    await page.getByTestId('connect-save-ssh-btn').click();
    await page.getByTestId('connect-auth-toggle').click();
    await page.getByTestId('connect-ssh-toggle').click();

    // Enter live serve URL and click RESCAN to measure handshake RTT cleanly
    await page.getByTestId('connect-url-input').fill(server.wsUrl);
    await page.getByTestId('connect-rescan-btn').click();

    const liveRow = page.getByTestId('live-session-row-0');
    await expect(liveRow).toBeVisible({ timeout: 10_000 });
    await expect(liveRow).toContainText(/Loopback · \d+\.\d ms/);
    await auditEditorialSlateScreen(page, 'screen02-populated-live');
    await saveM2Shot(page, 'm2_01_connect_remote.png');

    // Attach via Observe button -> /debug in read-only mode
    await page.getByTestId('live-session-observe-0').click();
    await expect(page).toHaveURL(/\/debug$/, { timeout: 10_000 });

    const pcRow = page.locator('[data-reg="pc"]');
    await expect(pcRow).toBeVisible({ timeout: 10_000 });
    await expect(pcRow).toContainText(/0x[0-9a-f]{8}/);
    await expect(page.getByTestId('debug-observe-pill')).toContainText('OBSERVE');
    await expect(page.getByTestId('statusbar-observe-pill')).toHaveText('OBSERVE');
    await expect(page.getByTestId('debug-step-btn')).toBeDisabled();
    await expect(page.getByTestId('debug-run-btn')).toBeDisabled();
    await auditEditorialSlateScreen(page, 'screen02-observe-debug');
    await saveM2Shot(page, 'm2_03_observe_readonly.png');

    const initialPcText = await pcRow.innerText();

    // Drive external GDB step over TCP without touching the browser UI -> expect automatic live PC sync
    const gdbReply = await sendGdbStepOverTcp(gdbPort);
    expect(gdbReply).toMatch(/^\$T/);
    await expect(pcRow).not.toHaveText(initialPcText, { timeout: 10_000 });

    // Open status bar Connection / GDB / ctl popover and fill discovered GDB port
    await page.getByTestId('statusbar-connection-btn').click();
    await expect(page.getByTestId('connection-popover')).toBeVisible();
    await page.getByTestId('popover-gdb-port-input').fill(String(gdbPort));
    await expect(page.getByTestId('popover-gdb-command')).toContainText(`:${gdbPort}`);
    await expect(page.getByTestId('popover-ctl-command')).toContainText('ra8_emulator ctl sessions');
    await expect(page.getByTestId('connection-popover')).toContainText('1 syncs');
    await auditEditorialSlateScreen(page, 'screen02-gdb-popover');
    await saveM2Shot(page, 'm2_04_gdb_multiclient_popover.png');
  });
});
