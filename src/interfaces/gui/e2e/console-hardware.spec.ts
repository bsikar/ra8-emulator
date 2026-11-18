import { expect, test, type Page } from '@playwright/test';
import { auditEditorialSlateScreen } from './helpers/editorial-slate-audit';
import { startServeFixture, type ServedEmulatorHandle } from './helpers/serve-fixture';

async function connectAndOpenNav(page: Page, wsUrl: string, navTestId: string, urlRx: RegExp): Promise<void> {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto(`/launch?ws=${encodeURIComponent(wsUrl)}`);
  await expect(page.getByTestId('statusbar-connection-btn')).toContainText('127.0.0.1', { timeout: 10_000 });
  await page.getByTestId(navTestId).click();
  await expect(page).toHaveURL(urlRx);
}

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

test.describe('Console Monitor (/console) and Hardware Inspector (/hardware)', () => {
  let server: ServedEmulatorHandle | null = null;

  test.afterEach(async () => {
    if (server) {
      await server.stop();
      server = null;
    }
  });

  test('streams UART RX/TX on echo.elf, switches ASCII/Hex and timestamps, and audits Editorial Slate', async ({ page }) => {
    server = await startServeFixture('tests/fixtures/console/echo.elf');
    await connectAndOpenNav(page, server.wsUrl, 'nav-console', /\/console$/);
    await expect(page.getByTestId('console-stream-viewport')).toBeVisible();
    await expect(page.locator('body')).toContainText('UART SERIAL STREAM');

    await page.getByTestId('topbar-run-toggle').click();
    await page.getByTestId('console-trigger-input').fill('hello');
    await page.getByTestId('console-trigger-pause').uncheck();
    await page.getByTestId('console-trigger-add').click();

    await page.getByTestId('console-tx-input').fill('hello');
    await page.getByTestId('console-send-btn').click();
    await expect(page.getByTestId('console-stream-viewport')).toContainText('hello', { timeout: 10_000 });

    await page.getByTestId('console-mode-hex').click();
    await expect(page.getByTestId('console-stream-viewport')).toContainText('68 65 6c 6c 6f');
    await page.getByTestId('console-mode-ascii').click();
    await page.getByTestId('console-ts-virtual').click();

    await auditBothViewports(page, 'console-echo');
  });

  test('inspects /hardware peripheral MMIO, 64B read, switch IO, and audits Editorial Slate', async ({ page }) => {
    server = await startServeFixture('tests/fixtures/gpio/blink.elf');
    await connectAndOpenNav(page, server.wsUrl, 'nav-hardware', /\/hardware$/);
    await expect(page.locator('body')).toContainText('FITTED PARTS');

    await page.getByTestId('hardware-mmio-read-btn').click();
    await expect(page.getByTestId('hardware-mmio-raw')).toContainText('0x40000000:', { timeout: 10_000 });
    await page.getByTestId('hardware-rtc-refresh').click();
    await page.getByTestId('hardware-sw-0').click();

    await auditBothViewports(page, 'hardware-blink');
  });
});
