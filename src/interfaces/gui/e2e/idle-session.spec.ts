import fs from 'node:fs';
import path from 'node:path';
import { expect, test } from '@playwright/test';
import { startServeFixture } from './helpers/serve-fixture';

test('idle backend accepts browser firmware, closes, and loads again without restarting', async ({ page }) => {
  const server = await startServeFixture(null);
  try {
    await page.goto(`/launch?ws=${encodeURIComponent(server.wsUrl)}`);
    await expect(page.getByTestId('statusbar-connection-btn')).toContainText(server.wsUrl);
    await page.getByTestId('nav-debug').click();
    await expect(page.getByText('No firmware loaded', { exact: true })).toBeVisible();
    await expect(page.getByTestId('debug-step-btn')).toBeDisabled();
    await expect(page.getByTestId('topbar-run-toggle')).toBeDisabled();

    const repo = path.resolve(process.cwd(), '../../..');
    const bytes = fs.readFileSync(path.join(repo, 'examples/gpio/blink.elf'));
    for (let attempt = 0; attempt < 2; attempt++) {
      if (attempt === 0) {
        await page.getByTestId('idle-open-elf').click();
        await page.getByTestId('open-file-input').setInputFiles(path.join(repo, 'examples/gpio/blink.elf'));
        await page.getByTestId('open-submit-btn').click();
      } else {
        const transfer = await page.evaluateHandle((image) => {
          const dt = new DataTransfer();
          dt.items.add(new File([new Uint8Array(image)], 'blink.elf'));
          return dt;
        }, [...bytes]);
        await page.locator('.es-shell').dispatchEvent('drop', { dataTransfer: transfer });
        await transfer.dispose();
      }
      await expect(page.getByTestId('debug-step-btn')).toBeEnabled();
      const pc = page.locator('[data-reg="pc"]');
      await expect(pc).toContainText(/0x[0-9a-f]{8}/);
      const initial = await pc.innerText();
      await page.getByTestId('debug-step-btn').click();
      await expect(pc).not.toHaveText(initial);
      if (attempt === 1) {
        await page.getByTestId('topbar-run-toggle').click();
        await expect(page.getByTestId('topbar-run-toggle')).toHaveText('Pause');
      }
      await page.getByTestId('debug-close-session-btn').click();
      await expect(page.getByText('No firmware loaded', { exact: true })).toBeVisible();
      await expect(page.getByTestId('debug-step-btn')).toBeDisabled();
      await expect(page.getByTestId('statusbar-connection-btn')).toContainText(server.wsUrl);
    }
  } finally {
    await server.stop();
  }
});
