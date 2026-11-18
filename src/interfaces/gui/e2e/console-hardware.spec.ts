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

  test('streams UART RX/TX on echo.elf, switches stream tabs/modes, resolves source line, and audits Editorial Slate', async ({ page }) => {
    server = await startServeFixture('tests/fixtures/console/echo.elf');
    await connectAndOpenNav(page, server.wsUrl, 'nav-console', /\/console$/);
    await expect(page.getByTestId('console-stream-viewport')).toBeVisible();
    await expect(page.locator('body')).toContainText('UART SERIAL STREAM');

    await page.getByTestId('console-tab-swo').click();
    await expect(page.getByTestId('console-stream-viewport')).toContainText('No SWO trace packets');
    await page.getByTestId('console-tab-all').click();

    await page.getByTestId('topbar-run-toggle').click();
    await page.getByTestId('console-trigger-action-marker').click();
    await page.getByTestId('console-trigger-input').fill('hello');
    await page.getByTestId('console-trigger-add').click();

    await page.getByTestId('console-tx-input').fill('hello');
    await page.getByTestId('console-send-btn').click();
    await expect(page.getByTestId('console-stream-viewport')).toContainText('hello', { timeout: 10_000 });

    await page.getByTestId('console-mode-hex').click();
    await expect(page.getByTestId('console-stream-viewport')).toContainText('68 65 6c 6c 6f');
    await page.getByTestId('console-mode-ascii').click();
    await page.getByTestId('console-ts-virtual').click();

    await page.getByTestId('console-source-line-btn').click();
    await expect(page.getByTestId('console-source-line-out')).toBeVisible();
    await page.getByTestId('console-copy-btn').click();

    await auditBothViewports(page, 'console-echo');
  });

  test('inspects 3-column /hardware layout, adaptive rate, faults, MMIO blocks, and audits Editorial Slate', async ({ page }) => {
    server = await startServeFixture('tests/fixtures/gpio/blink.elf');
    await connectAndOpenNav(page, server.wsUrl, 'nav-hardware', /\/hardware$/);
    await expect(page.locator('body')).toContainText('FITTED PARTS');
    await expect(page.getByTestId('hardware-lcd-canvas')).toBeVisible();
    await expect(page.getByTestId('hardware-mmio-filter')).toBeVisible();

    await page.getByTestId('hardware-lcd-rate').selectOption('slow_0_1x');
    await page.getByTestId('hardware-lcd-rate').selectOption('rate_100x');
    const lcdBox = await page.getByTestId('hardware-lcd-canvas').boundingBox();
    expect(lcdBox).not.toBeNull();
    await page.mouse.move(lcdBox!.x + lcdBox!.width / 2, lcdBox!.y + lcdBox!.height / 2);
    await expect(page.getByTestId('hardware-crosshair-readout')).toContainText(/x:\s*\d+\s+y:\s*\d+/);
    await page.getByTestId('hardware-camera-apply').click();

    await page.getByTestId('hardware-plug-input').fill('max17048@i2c:riic@0x36');
    await page.getByTestId('hardware-plug-btn').click();
    await expect(page.locator('body')).toContainText('i2c:riic@0x36', { timeout: 10_000 });

    await page.getByTestId('hardware-fault-chip-stretch').click();
    await expect(page.getByTestId('hardware-fault-rule')).toHaveValue('stretch:25000');
    await page.getByTestId('hardware-fault-inject-btn').click();
    await expect(page.locator('body')).toContainText('max17048@i2c:riic@0x36=stretch:25000', { timeout: 10_000 });
    await page.getByTestId('hardware-fault-clear-btn').click();

    await page.getByTestId('hardware-mmio-chip-SCI8').click();
    await expect(page.getByTestId('hardware-mmio-dump')).toContainText('SCI_B UART', { timeout: 10_000 });
    await page.getByTestId('hardware-mmio-read-btn').click();
    await expect(page.getByTestId('hardware-mmio-raw')).toContainText('0x40000000:', { timeout: 10_000 });
    await page.getByTestId('hardware-rtc-refresh').click();
    await page.getByTestId('hardware-sw-0').click();

    await auditBothViewports(page, 'hardware-blink-split');

    const switcher = page.getByTestId('hardware-layout-switcher');
    await switcher.getByRole('button', { name: 'Board' }).click();
    await expect(page.getByTestId('hardware-lcd-canvas')).toBeVisible();
    await expect(page.locator('body')).toContainText('FITTED PARTS');

    await switcher.getByRole('button', { name: 'Debugger' }).click();
    await expect(page.getByTestId('hardware-mmio-filter')).toBeVisible();
    await expect(page.locator('body')).toContainText('FITTED PARTS');

    await switcher.getByRole('button', { name: 'Split' }).click();
  });
});
