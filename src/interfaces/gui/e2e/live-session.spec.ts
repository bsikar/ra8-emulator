import { expect, test } from '@playwright/test';
import { auditEditorialSlateScreen } from './helpers/editorial-slate-audit';
import { startServeFixture, type ServedEmulatorHandle } from './helpers/serve-fixture';

test.describe('Live ra8_emulator serve WebSocket session', () => {
  let server: ServedEmulatorHandle | null = null;

  test.afterEach(async () => {
    if (server) {
      await server.stop();
      server = null;
    }
  });

  test('connects browser PWA over WebSocket, inspects halted registers, and single-steps CPU0', async ({ page }) => {
    server = await startServeFixture('tests/fixtures/gpio/blink.elf');

    await page.goto(`/launch?ws=${encodeURIComponent(server.wsUrl)}`);
    await expect(page.getByTestId('shell-statusbar')).toContainText(server.wsUrl, { timeout: 10_000 });
    await expect(page.getByTestId('launch-error')).toBeHidden();
    await auditEditorialSlateScreen(page, 'live-launch-connected');

    await page.getByTestId('nav-debug').click();
    await expect(page).toHaveURL(/\/debug$/);

    const pcRow = page.locator('[data-reg="pc"]');
    await expect(pcRow).toBeVisible({ timeout: 10_000 });
    await expect(pcRow).toContainText(/0x[0-9a-f]{8}/);
    const initialPcText = await pcRow.innerText();

    await expect(page.getByTestId('debug-disasm')).toBeVisible();
    await auditEditorialSlateScreen(page, 'live-debug-halted');

    await page.getByTestId('debug-step-btn').click();
    await expect(pcRow).not.toHaveText(initialPcText, { timeout: 10_000 });
    await auditEditorialSlateScreen(page, 'live-debug-after-step');
  });
});
