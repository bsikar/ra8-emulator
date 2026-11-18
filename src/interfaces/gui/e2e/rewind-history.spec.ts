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

test.describe('Time-Travel Rewind (/rewind) with Live History Checkpoints', () => {
  let server: ServedEmulatorHandle | null = null;
  let historyDir: string | null = null;

  test.afterEach(async () => {
    if (server) {
      await server.stop();
      server = null;
    }
    if (historyDir && fs.existsSync(historyDir)) {
      fs.rmSync(historyDir, { recursive: true, force: true });
      historyDir = null;
    }
  });

  test('records checkpoints with --history, seeks, diffs states, toggles DAG layout, and audits Editorial Slate', async ({ page }) => {
    historyDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ra8-gui-hist-'));
    server = await startServeFixture('tests/fixtures/gpio/blink.elf', ['--history', historyDir, '--checkpoint-every', '4']);

    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto(`/launch?ws=${encodeURIComponent(server.wsUrl)}`);
    await expect(page.getByTestId('statusbar-connection-btn')).toContainText('127.0.0.1', { timeout: 10_000 });

    await page.getByTestId('topbar-run-toggle').click();
    await page.waitForTimeout(150);
    await page.getByTestId('topbar-run-toggle').click();
    await expect(page.getByTestId('topbar-step')).toBeEnabled({ timeout: 10_000 });

    await page.getByTestId('nav-rewind').click();
    await expect(page).toHaveURL(/\/rewind$/);
    await expect(page.locator('body')).toContainText('EXECUTION BRANCHES');
    await expect(page.getByTestId('rewind-switch-0')).toBeVisible({ timeout: 10_000 });

    await page.getByTestId('rewind-seek-prev').click();
    await page.getByTestId('rewind-seek-zero').click();

    await page.getByTestId('rewind-diff-a').fill('0');
    await page.getByTestId('rewind-diff-b').fill('latest');
    await page.getByTestId('rewind-diff-btn').click();
    await expect(page.getByTestId('rewind-diff-row-0')).toBeVisible({ timeout: 10_000 });

    await page.getByTestId('rewind-layout-waterfall').click();
    await expect(page.getByTestId('rewind-layout-waterfall')).toHaveClass(/is-active/);
    await page.getByTestId('rewind-layout-spine').click();

    await auditBothViewports(page, 'rewind-history');
  });
});
