import fs from 'node:fs';
import path from 'node:path';
import { expect, test, type Page } from '@playwright/test';
import { auditEditorialSlateScreen } from './helpers/editorial-slate-audit';

const SCREENSHOT_DIR = path.resolve(process.cwd(), 'test-results', 'screenshots');

function ensureScreenshotDir(): void {
  fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });
}

async function seedWorkspaces(page: Page): Promise<void> {
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
    },
    {
      id: 'ws-ra8e1',
      name: 'FPB-RA8E1 Signed Bootloader',
      path: '~/work/boot_signed_v2.4.elf',
      wsUrl: 'ws://127.0.0.1:4569',
      pinned: false,
      lastOpenedIso: new Date(now - 3600_000).toISOString(),
      targetModel: 'FPB-RA8E1',
      archSummary: 'Cortex-M85 (360 MHz)',
      modeLabel: 'Prebuilt .elf',
    },
  ];
  await page.evaluate((payload) => {
    localStorage.setItem('ra8.recentWorkspaces.v1', JSON.stringify(payload));
  }, entries);
}

function buildTestExtensionPayload(): { manifestJson: string; workerJs: string } {
  const manifestJson = JSON.stringify(
    {
      id: 'acme.ping-probe',
      name: 'ping-probe',
      publisher: 'acme',
      displayName: 'Ping Probe Worker',
      version: '1.0.0',
      description: 'Verifies live Blob Web Worker execution and panel telemetry.',
      activationEvents: ['onStartupFinished'],
      contributes: {
        commands: [{ command: 'acme.ping', title: 'Run Worker Ping' }],
        keybindings: [],
        panels: [{ id: 'acme.ping.panel', title: 'Ping Output', location: 'panel' }],
      },
    },
    null,
    2
  );
  const workerJs = [
    'async function activate() {',
    "  await ra8.commands.registerCommand('acme.ping', async () => {",
    '    const exec = await ra8.debug.getExecutionState();',
    "    await ra8.views.postPanelState('acme.ping.panel', { status: 'ok', connected: exec.connected });",
    "    await ra8.window.showInformationMessage('Worker Ping OK');",
    '    return { ok: true };',
    '  });',
    '}',
  ].join('\n');
  return { manifestJson, workerJs };
}

test.describe('IDE Ergonomics: Shift+Shift, Vim, and Web Worker Extensions', () => {
  test('opens Search Everywhere on clean Shift+Shift, rejects Shift+A, and supports tabs/fuzzy/0x jumps', async ({
    page,
  }) => {
    ensureScreenshotDir();
    await page.goto('/launch');
    await seedWorkspaces(page);
    await page.reload();

    await page.keyboard.down('Shift');
    await page.keyboard.press('A');
    await page.keyboard.up('Shift');
    await expect(page.getByTestId('search-everywhere-dialog')).toBeHidden();

    await page.keyboard.press('Shift');
    await page.keyboard.press('Shift');
    const dialog = page.getByTestId('search-everywhere-dialog');
    await expect(dialog).toBeVisible();

    for (const tab of ['all', 'files', 'symbols', 'text', 'actions']) {
      await expect(page.getByTestId(`search-everywhere-tab-${tab}`)).toBeVisible();
    }

    const input = page.getByTestId('search-everywhere-input');
    await input.fill('ethos');
    await expect(dialog.locator('mark.fuzzy-hit').first()).toBeVisible();

    for (const vp of [
      { width: 1440, height: 900 },
      { width: 1280, height: 720 },
    ]) {
      await page.setViewportSize(vp);
      await auditEditorialSlateScreen(page, `shift-shift-search-${vp.width}x${vp.height}`);
      if (vp.width === 1440) {
        await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'shift-shift-search.png') });
      }
    }

    await input.fill(':42');
    await expect(dialog).toContainText('Go to line 42');
    await input.fill('0x20001000');
    await expect(dialog).toContainText('Jump to address 0x20001000');
    await page.keyboard.press('Enter');
    await expect(dialog).toBeHidden();
    await expect(page).toHaveURL(/\/debug$/);
  });

  test('supports Vim modal navigation, marks, settings toggle, and :ex commands', async ({ page }) => {
    await page.goto('/launch');
    await seedWorkspaces(page);
    await page.reload();

    const vimBadge = page.getByTestId('statusbar-vim');
    await expect(vimBadge).toHaveText('VIM: OFF');

    await page.getByTestId('settings-trigger').click();
    await page.getByTestId('settings-vim-toggle').click();
    await expect(vimBadge).toHaveText('VIM: NORMAL');
    await page.keyboard.press('Escape');

    await page.locator('main').click({ position: { x: 24, y: 24 } });
    await page.keyboard.press('j');
    await expect(page.getByTestId('workspace-row-ws-ra8d2')).toHaveClass(/is-selected/);

    await page.keyboard.press('G');
    await expect(page.getByTestId('workspace-row-ws-ra8e1')).toHaveClass(/is-selected/);

    await page.keyboard.press('g');
    await page.keyboard.press('g');
    await expect(page.getByTestId('workspace-row-ws-ra8p1')).toHaveClass(/is-selected/);

    await page.keyboard.press('m');
    await page.keyboard.press('a');
    await page.keyboard.press('G');
    await expect(page.getByTestId('workspace-row-ws-ra8e1')).toHaveClass(/is-selected/);
    await page.keyboard.press("'");
    await page.keyboard.press('a');
    await expect(page.getByTestId('workspace-row-ws-ra8p1')).toHaveClass(/is-selected/);

    await page.keyboard.press(':');
    await page.getByTestId('vim-ex-input').fill('vim off');
    await page.keyboard.press('Enter');
    await expect(vimBadge).toHaveText('VIM: OFF');

    await page.keyboard.press(':');
    await page.getByTestId('vim-ex-input').fill('vim on');
    await page.keyboard.press('Enter');
    await expect(vimBadge).toHaveText('VIM: NORMAL');
  });

  test('installs, runs, disables, and uninstalls real Web Worker extensions with Vim active', async ({ page }) => {
    ensureScreenshotDir();
    await page.goto('/launch');
    await seedWorkspaces(page);
    await page.reload();

    await page.getByTestId('statusbar-vim').click();
    await expect(page.getByTestId('statusbar-vim')).toHaveText('VIM: NORMAL');

    await page.keyboard.press('ControlOrMeta+Shift+X');
    const extDialog = page.getByTestId('extensions-sheet-dialog');
    await expect(extDialog).toBeVisible();
    await expect(page.getByTestId('ext-empty-state')).toBeVisible();

    await page.getByTestId('ext-toggle-install-drawer').click();
    const { manifestJson, workerJs } = buildTestExtensionPayload();
    await page.getByTestId('ext-manifest-json').fill(manifestJson);
    await page.getByTestId('ext-source-js').fill(workerJs);
    await page.getByTestId('ext-install-submit').click();

    await expect(page.getByTestId('ext-row-acme.ping-probe')).toContainText('active', { timeout: 10_000 });
    await page.getByTestId('ext-run-acme.ping').click();
    await expect(page.getByTestId('ext-messages')).toContainText('Worker Ping OK', { timeout: 10_000 });
    await expect(page.getByTestId('ext-panel-acme.ping.panel')).toContainText('"status":"ok"');

    for (const vp of [
      { width: 1440, height: 900 },
      { width: 1280, height: 720 },
    ]) {
      await page.setViewportSize(vp);
      await auditEditorialSlateScreen(page, `vim-and-extensions-${vp.width}x${vp.height}`);
      if (vp.width === 1440) {
        await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'vim-and-extensions.png') });
      }
    }

    await page.getByTestId('ext-toggle-acme.ping-probe').click();
    await expect(page.getByTestId('ext-row-acme.ping-probe')).toContainText('idle');
    await expect(page.getByTestId('ext-run-acme.ping')).toBeDisabled();

    await page.getByTestId('ext-uninstall-acme.ping-probe').click();
    await expect(page.getByTestId('ext-empty-state')).toBeVisible();
  });
});
