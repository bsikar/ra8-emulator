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

test.describe('Quick ELF Switching, Viewport Drop, Open Recent, and Reload', () => {
  let served: ServedEmulatorHandle;
  let tempWorkspace = '';
  let repoRoot = '';

  test.beforeAll(async () => {
    repoRoot = path.resolve(process.cwd(), '..', '..', '..');
    tempWorkspace = fs.mkdtempSync(path.join(os.tmpdir(), 'ra8-elf-reload-e2e-'));
    fs.copyFileSync(
      path.join(repoRoot, 'tests', 'fixtures', 'uart', 'uart_irq_echo.elf'),
      path.join(tempWorkspace, 'firmware.elf')
    );
    served = await startServeFixture(undefined, ['--workspace', tempWorkspace]);
  });

  test.afterAll(async () => {
    await served?.stop();
    if (tempWorkspace && fs.existsSync(tempWorkspace)) {
      fs.rmSync(tempWorkspace, { recursive: true, force: true });
    }
  });

  test('viewport drag-and-drop loads firmware paused at reset and persists Open Recent in IndexedDB across reload', async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto(`/launch?ws=${encodeURIComponent(served.wsUrl)}`);
    await expect(page.getByTestId('statusbar-connection-btn')).toContainText('127.0.0.1', { timeout: 10_000 });

    const blinkBytes = fs.readFileSync(path.join(repoRoot, 'tests', 'fixtures', 'gpio', 'blink.elf'));
    const dataTransfer = await page.evaluateHandle((bytes) => {
      const dt = new DataTransfer();
      dt.items.add(new File([new Uint8Array(bytes)], 'blink.ra8app', { type: 'application/octet-stream' }));
      return dt;
    }, [...blinkBytes]);

    await page.locator('.es-shell').dispatchEvent('dragover', { dataTransfer });
    await expect(page.getByTestId('drop-veil')).toBeVisible();
    await page.locator('.es-shell').dispatchEvent('drop', { dataTransfer });

    await expect(page).toHaveURL(/\/debug$/, { timeout: 10_000 });
    await expect(page).toHaveTitle('blink.ra8app — RA8 Emulator');
    await expect(page.locator('[data-reg="pc"]')).toContainText(/0x[0-9a-f]{8}/, { timeout: 10_000 });
    await expect(page.getByTestId('topbar-run-toggle')).toHaveText('Continue');

    await page.getByTestId('menu-file').click();
    await expect(page.getByTestId('menuitem-recent-elf-0')).toContainText('blink.ra8app');
    await page.keyboard.press('Escape');
    await auditBothViewports(page, 'elf-drop-debug');

    await page.reload();
    await expect(page.getByTestId('statusbar-connection-btn')).toContainText('Offline');
    await page.getByTestId('menu-file').click();
    await expect(page.getByTestId('menuitem-recent-elf-0')).toContainText('blink.ra8app', { timeout: 10_000 });
    await page.getByTestId('menuitem-recent-elf-0').click();

    await expect(page.getByTestId('statusbar-connection-btn')).toContainText('127.0.0.1', { timeout: 10_000 });
    await expect(page.locator('[data-reg="pc"]')).toContainText(/0x[0-9a-f]{8}/, { timeout: 10_000 });
    await expect(page.getByTestId('topbar-run-toggle')).toHaveText('Continue');
  });

  test('Reload ELF via Ctrl+R re-reads rebuilt workspace ELF at reset and relocates symbol breakpoints', async ({ page }) => {
    fs.copyFileSync(
      path.join(repoRoot, 'tests', 'fixtures', 'uart', 'uart_irq_echo.elf'),
      path.join(tempWorkspace, 'firmware.elf')
    );

    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto(`/launch?ws=${encodeURIComponent(served.wsUrl)}`);
    await expect(page.getByTestId('statusbar-connection-btn')).toContainText('127.0.0.1', { timeout: 10_000 });

    await page.getByTestId('launch-action-open').click();
    await expect(page).toHaveURL(/\/open$/);
    await page.getByTestId('open-entry-firmware.elf').click();
    await expect(page.getByTestId('open-elf-summary')).toContainText('firmware.elf', { timeout: 10_000 });
    await page.getByTestId('open-submit-btn').click();

    await expect(page).toHaveURL(/\/debug$/, { timeout: 10_000 });
    const pcRow = page.locator('[data-reg="pc"]');
    await expect(pcRow).toContainText(/0x[0-9a-f]{8}/, { timeout: 10_000 });
    const uartResetPc = await pcRow.innerText();
    await expect(page.getByTestId('topbar-run-toggle')).toHaveText('Continue');

    await page.getByTestId('debug-jump-input').fill('main');
    await page.getByTestId('debug-add-break-btn').click();
    const bpItems = page.locator('[data-testid^="debug-bp-item-"]');
    await expect(bpItems).toHaveCount(1, { timeout: 10_000 });
    await expect(bpItems.first()).toContainText('main');

    await page.getByTestId('debug-step-btn').click();
    await expect(pcRow).not.toHaveText(uartResetPc, { timeout: 10_000 });

    // Rebuild firmware.elf on disk with pacbti_smoke.elf where main moves to 0x02000024
    fs.copyFileSync(
      path.join(repoRoot, 'tests', 'fixtures', 'pacbti', 'pacbti_smoke.elf'),
      path.join(tempWorkspace, 'firmware.elf')
    );

    await page.getByTestId('debug-code-viewport').click();
    await page.keyboard.press('Control+r');

    await expect(page.getByText(/Reloaded firmware\.elf at reset/)).toBeVisible({ timeout: 10_000 });
    await expect(bpItems).toHaveCount(1, { timeout: 10_000 });
    await expect(bpItems.first()).toContainText('main');
    await expect(page.getByTestId('topbar-run-toggle')).toHaveText('Continue');
    await expect(pcRow).not.toHaveText(uartResetPc, { timeout: 10_000 });

    await page.getByTestId('topbar-run-toggle').click();
    await expect(pcRow).toContainText('0x02000024', { timeout: 10_000 });
    await auditBothViewports(page, 'elf-reload-relocated');
  });
});
