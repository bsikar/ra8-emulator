import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { expect, test, type Page } from '@playwright/test';
import { auditEditorialSlateScreen } from './helpers/editorial-slate-audit';
import { startServeFixture, type ServedEmulatorHandle } from './helpers/serve-fixture';

async function auditBothViewports(page: Page, prefix: string): Promise<void> {
  for (const vp of [
    { width: 1440, height: 900 },
    { width: 1280, height: 720 },
  ]) {
    await page.setViewportSize(vp);
    await auditEditorialSlateScreen(page, `${prefix}-${vp.width}x${vp.height}`);
  }
  await page.setViewportSize({ width: 1440, height: 900 });
}

function resolveRepoRoot(): string {
  let dir = process.cwd();
  for (let i = 0; i < 8; i++) {
    if (fs.existsSync(path.join(dir, 'build.zig'))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return path.resolve(process.cwd(), '..', '..', '..');
}

async function verifyStateDiffAndArchive(page: Page, snapFile: string): Promise<void> {
  await page.getByTestId('rewind-diff-a').fill('0');
  await page.getByTestId('rewind-diff-b').fill('latest');
  await page.getByTestId('rewind-diff-btn').click();
  await expect(page.getByTestId('rewind-diff-col-regs')).toBeVisible({ timeout: 10_000 });
  await expect(page.getByTestId('rewind-diff-col-pages')).toBeVisible();
  await expect(page.getByTestId('rewind-diff-col-periphs')).toBeVisible();
  await expect(page.getByTestId('rewind-diff-row-0')).toBeVisible();
  await expect(page.getByTestId('rewind-diff-page-0')).toBeVisible();
  await expect(page.getByTestId('rewind-diff-periph-0')).toBeVisible();
  await expect(page.getByTestId('rewind-diff-span')).toBeVisible();

  await page.getByTestId('rewind-diff-tab-pages').click();
  await expect(page.getByTestId('rewind-diff-col-regs')).toBeHidden();
  await page.getByTestId('rewind-diff-tab-all').click();
  await expect(page.getByTestId('rewind-diff-col-regs')).toBeVisible();

  await page.getByTestId('rewind-diff-swap-btn').click();
  await expect(page.getByTestId('rewind-diff-a')).toHaveValue('latest');
  await expect(page.getByTestId('rewind-diff-b')).toHaveValue('0');
  await expect(page.getByTestId('rewind-diff-row-0')).toBeVisible({ timeout: 10_000 });

  await page.getByTestId('rewind-snapshot-name').fill(snapFile);
  await page.getByTestId('rewind-snapshot-save').click();
  await expect(page.locator('.toast-msg').filter({ hasText: `Saved snapshot ${snapFile}` })).toBeVisible({ timeout: 10_000 });
  await page.getByTestId('rewind-snapshot-restore').click();
  await expect(page.locator('.toast-msg').filter({ hasText: `Restored snapshot ${snapFile}` })).toBeVisible({ timeout: 10_000 });

  const [download] = await Promise.all([
    page.waitForEvent('download'),
    page.getByTestId('rewind-export-tar-btn').click(),
  ]);
  expect(download.suggestedFilename()).toBe('ra8-history-bundle.tar');
}

test.describe('Time-Travel Rewind (/rewind) with Live History Checkpoints', () => {
  let server: ServedEmulatorHandle | null = null;
  let historyDir: string | null = null;
  let artifactsDir: string | null = null;
  const snapFile = 'e2e-rewind-ckpt.ra8snap';

  test.afterEach(async () => {
    if (server) {
      await server.stop();
      server = null;
    }
    for (const dir of [historyDir, artifactsDir]) {
      if (dir && fs.existsSync(dir)) {
        fs.rmSync(dir, { recursive: true, force: true });
      }
    }
    historyDir = null;
    artifactsDir = null;
    const straySnap = path.join(resolveRepoRoot(), snapFile);
    if (fs.existsSync(straySnap)) {
      fs.rmSync(straySnap, { force: true });
    }
  });

  test('exercises setMarker, stepBack, seek, 3-col diff, Swap A-B, snapshot/restore, DAG modes, and Editorial Slate audits', async ({ page }) => {
    historyDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ra8-gui-hist-'));
    artifactsDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ra8-gui-art-'));
    server = await startServeFixture('tests/fixtures/uart/uart_irq_echo.elf', [
      '--history',
      historyDir,
      '--checkpoint-every',
      '4',
      '--artifacts-root',
      artifactsDir,
    ]);

    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto(`/launch?ws=${encodeURIComponent(server.wsUrl)}`);
    await expect(page.getByTestId('statusbar-connection-btn')).toContainText('127.0.0.1', { timeout: 10_000 });

    await page.getByTestId('nav-rewind').click();
    await expect(page).toHaveURL(/\/rewind$/);
    await expect(page.locator('body')).toContainText('EXECUTION BRANCHES');
    await expect(page.getByTestId('rewind-switch-0')).toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId('rewind-frame-status')).toBeVisible({ timeout: 10_000 });

    await page.getByTestId('rewind-advance-btn').click();
    await expect(page.getByTestId('rewind-active-cursor')).not.toHaveText(/· r0$/, { timeout: 10_000 });
    await page.getByTestId('rewind-advance-btn').click();
    await expect(page.getByTestId('shell-statusbar')).toContainText('16.00ms', { timeout: 10_000 });

    await page.getByTestId('rewind-bookmark-toggle').click();
    await expect(page.getByTestId('rewind-marker-place')).toHaveValue(/^0x[0-9a-f]{8}$/i, { timeout: 10_000 });
    await page.getByTestId('rewind-marker-name').fill('loop_pt');
    await page.getByTestId('rewind-marker-btn').click();
    await expect(page.getByTestId('rewind-bm-loop_pt')).toBeVisible({ timeout: 10_000 });

    await page.getByTestId('rewind-seek-input').fill('iter 4');
    await page.getByTestId('rewind-seek-btn').click();
    await expect(page.getByTestId('shell-statusbar')).toContainText('2.00ms', { timeout: 10_000 });
    await page.getByTestId('rewind-seek-prev').click();
    await page.waitForTimeout(200);
    await page.getByTestId('rewind-step-back-btn').click();
    await page.waitForTimeout(200);
    await page.getByTestId('rewind-bm-loop_pt').click();
    await page.waitForTimeout(200);
    await page.getByTestId('rewind-seek-zero').click();

    await verifyStateDiffAndArchive(page, snapFile);

    await page.getByTestId('rewind-layout-waterfall').click();
    await expect(page.getByTestId('rewind-layout-waterfall')).toHaveClass(/is-active/);
    await page.getByTestId('rewind-layout-spine').click();
    await expect(page.getByTestId('rewind-layout-spine')).toHaveClass(/is-active/);
    await expect(page.locator('.toast-item.is-fault')).toHaveCount(0);
    await expect(page.locator('.toast-item')).toHaveCount(0, { timeout: 8_000 });

    await auditBothViewports(page, 'rewind-history');
  });
});
