import fs from 'node:fs';
import path from 'node:path';
import { expect, test, type Page } from '@playwright/test';
import { auditEditorialSlateScreen } from './helpers/editorial-slate-audit';

const SCREENSHOT_DIR = path.resolve(process.cwd(), 'test-results', 'screenshots');

function ensureScreenshotDir(): void {
  fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });
}

async function seedTestWorkspacesViaStorage(page: Page): Promise<void> {
  const now = Date.now();
  const entries = [
    {
      id: 'ws-ra8p1',
      name: 'RA8P1 Vision & Ethos-U55 HMI',
      path: '~/work/ra8p1-vision-hmi',
      wsUrl: 'ws://127.0.0.1:4567',
      pinned: true,
      lastOpenedIso: new Date(now - 8 * 60_000).toISOString(),
      targetModel: 'EK-RA8P1',
      archSummary: 'Cortex-M85 + M33 + Ethos-U55',
      modeLabel: 'Emulator',
      artifactSummary: 'ek_ra8p1.board',
      checkpointCount: 1842,
    },
    {
      id: 'ws-ra8d2',
      name: 'EK-RA8D2 Dual-Core Display',
      path: '~/work/ra8d2-glcdc-rtos',
      wsUrl: 'ws://127.0.0.1:4568',
      pinned: false,
      lastOpenedIso: new Date(now - 24 * 60_000).toISOString(),
      targetModel: 'EK-RA8D2',
      archSummary: 'Cortex-M85 + Cortex-M33',
      modeLabel: 'Emulator',
      artifactSummary: 'ek_ra8d2.board',
    },
    {
      id: 'ws-ra4t1',
      name: 'FPB-RA4T1 FOC Motor Inverter',
      path: 'ssh://10.0.4.18:~/work/ra4t1-foc-inverter',
      wsUrl: 'ws://10.0.4.18:4567',
      pinned: false,
      lastOpenedIso: new Date(now - 2 * 3600_000).toISOString(),
      targetModel: 'FPB-RA4T1',
      archSummary: 'Cortex-M33 (100 MHz)',
      modeLabel: 'Hardware (SWD / HIL)',
      artifactSummary: 'J-Link SN 1050188304',
    },
    {
      id: 'ws-ra8e1',
      name: 'FPB-RA8E1 Signed Bootloader',
      path: '~/work/boot_signed_v2.4.elf',
      wsUrl: 'ws://127.0.0.1:4569',
      pinned: false,
      lastOpenedIso: new Date(now - 24 * 3600_000).toISOString(),
      targetModel: 'FPB-RA8E1',
      archSummary: 'Cortex-M85 (360 MHz)',
      modeLabel: 'Prebuilt .elf',
      entryAddress: '0x02000400',
    },
  ];
  await page.evaluate((payload) => {
    localStorage.setItem('ra8.recentWorkspaces.v1', JSON.stringify(payload));
  }, entries);
}

test.describe('Launch Index & Inline Command Mode', () => {
  test('renders honest empty state on first boot at 1440x900 and 1280x720', async ({ page }) => {
    ensureScreenshotDir();
    for (const vp of [
      { width: 1440, height: 900 },
      { width: 1280, height: 720 },
    ]) {
      await page.setViewportSize(vp);
      await page.goto('/launch');
      await expect(page.getByTestId('launch-empty-state')).toBeVisible();
      await expect(page.getByTestId('launch-ws-input')).toBeVisible();
      await expect(page.getByText('RA8P1 Vision')).toHaveCount(0);
      await auditEditorialSlateScreen(page, `launch-empty-${vp.width}x${vp.height}`);
      if (vp.width === 1440) {
        await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'launch-empty.png') });
      }
    }
  });

  test('supports populated Workspace Index, pin, kebab, and + New Workspace at 1440x900 & 1280x720', async ({ page }) => {
    ensureScreenshotDir();
    await page.goto('/launch');
    await seedTestWorkspacesViaStorage(page);
    await page.reload();

    for (const vp of [
      { width: 1440, height: 900 },
      { width: 1280, height: 720 },
    ]) {
      await page.setViewportSize(vp);
      await expect(page.getByTestId('workspace-row-ws-ra8p1')).toBeVisible();
      await expect(page.getByTestId('workspace-row-ws-ra8e1')).toBeVisible();
      await auditEditorialSlateScreen(page, `launch-populated-${vp.width}x${vp.height}`);
      if (vp.width === 1440) {
        await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'launch-populated.png') });
      }
    }

    // Filter workspaces and clear
    const search = page.getByTestId('launch-search-input');
    await search.fill('Ethos');
    await expect(page.getByTestId('workspace-row-ws-ra8p1')).toBeVisible();
    await expect(page.getByTestId('workspace-row-ws-ra8e1')).toBeHidden();
    await search.fill('');

    // Toggle pin & kebab remove
    await page.getByTestId('workspace-pin-ws-ra8d2').click();
    await page.getByTestId('workspace-kebab-ws-ra8e1').click();
    await page.getByRole('menuitem', { name: 'Remove from Index' }).click();
    await expect(page.getByTestId('workspace-row-ws-ra8e1')).toBeHidden();

    // Navigate to /connect via Connect Remote button and return via back arrow
    await page.getByTestId('launch-action-connect').click();
    await expect(page).toHaveURL(/\/connect$/);
    await expect(page.getByTestId('connect-url-input')).toBeVisible();
    await auditEditorialSlateScreen(page, 'launch-to-connect');
    await page.getByTestId('connect-back-btn').click();
    await expect(page).toHaveURL(/\/launch$/);

    // Open + New Workspace modal and create an entry
    await page.getByTestId('launch-action-new').click();
    await expect(page.getByTestId('new-workspace-dialog')).toBeVisible();
    await auditEditorialSlateScreen(page, 'launch-new-workspace-dialog');
    await page.getByTestId('preset-fpb-ra4t1').click();
    await page.getByTestId('new-ws-create-btn').click();
    await expect(page.getByTestId('new-workspace-dialog')).toBeHidden();
    await expect(page.getByTestId('workspace-index-card').getByText('FPB-RA4T1 Session')).toBeVisible();
  });

  test('switches into inline > Launch Command Mode with ESC back to Workspaces', async ({ page }) => {
    ensureScreenshotDir();
    await page.goto('/launch');
    await seedTestWorkspacesViaStorage(page);
    await page.reload();

    const search = page.getByTestId('launch-search-input');
    await search.click();
    await search.fill('>');

    await expect(page.getByTestId('launch-command-card')).toBeVisible();
    await expect(page.getByText('SESSION & WORKSPACE COMMANDS')).toBeVisible();
    await expect(page.getByText('HARDWARE PROBES & BOARD COMPOSER')).toBeVisible();
    await expect(page.getByText('IDE & EXTENSIONS')).toBeVisible();

    for (const vp of [
      { width: 1440, height: 900 },
      { width: 1280, height: 720 },
    ]) {
      await page.setViewportSize(vp);
      await auditEditorialSlateScreen(page, `launch-command-mode-${vp.width}x${vp.height}`);
      if (vp.width === 1440) {
        await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'launch-command-mode.png') });
      }
    }

    await search.fill('board');
    await expect(page.getByTestId('launch-cmd-board-composer')).toBeVisible();
    await expect(page.getByTestId('launch-cmd-device-monitor')).toBeHidden();

    // Move focus onto a command button (away from search input) and press Escape
    await page.getByTestId('launch-cmd-board-composer').focus();
    await page.keyboard.press('Escape');
    await expect(page.getByTestId('launch-command-card')).toBeHidden();
    await expect(page.getByTestId('workspace-index-card')).toBeVisible();
  });
});
