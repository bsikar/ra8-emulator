import { expect, test, type Page } from '@playwright/test';
import { auditEditorialSlateScreen } from './helpers/editorial-slate-audit';
import { startServeFixture, type ServedEmulatorHandle } from './helpers/serve-fixture';

async function connectAndOpenDebug(page: Page, wsUrl: string): Promise<void> {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto(`/launch?ws=${encodeURIComponent(wsUrl)}`);
  await expect(page.getByTestId('statusbar-connection-btn')).toContainText('127.0.0.1', { timeout: 10_000 });
  await page.getByTestId('nav-debug').click();
  await expect(page).toHaveURL(/\/debug$/);
  await expect(page.locator('[data-reg="pc"]')).toContainText(/0x[0-9a-f]{8}/, { timeout: 10_000 });
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

test.describe('Workbench Debug (/debug) with Live Emulator RPC', () => {
  let server: ServedEmulatorHandle | null = null;

  test.afterEach(async () => {
    if (server) {
      await server.stop();
      server = null;
    }
  });

  test('edits registers, toggles disassembly breakpoints, pokes SRAM memory, and navigates via Vim', async ({ page }) => {
    server = await startServeFixture('tests/fixtures/gpio/blink.elf');
    await connectAndOpenDebug(page, server.wsUrl);
    await auditBothViewports(page, 'debug-blink-initial');

    // Layout switcher Board | Debugger | Split
    await page.getByTestId('layout-debugger-btn').click();
    await expect(page.getByTestId('debug-serial-tx-input')).toBeHidden();
    await page.getByTestId('layout-split-btn').click();
    await expect(page.getByTestId('debug-serial-tx-input')).toBeVisible();

    // Register groups & inline edit on r0
    await page.getByTestId('debug-reg-group-sys').click();
    await expect(page.locator('[data-reg="primask"]')).toBeVisible();
    await page.getByTestId('debug-reg-group-mve').click();
    await expect(page.locator('[data-reg="fpscr"]')).toBeVisible();
    await page.getByTestId('debug-reg-group-gpr').click();
    await page.locator('[data-reg="r0"] button.reg-val').click();
    const regInput = page.getByTestId('debug-reg-edit-input');
    await regInput.fill('0x00001234');
    await regInput.press('Enter');
    await expect(page.locator('[data-reg="r0"]')).toContainText('0x00001234', { timeout: 10_000 });

    // Gutter breakpoint toggle + Decomp / Mixed switch + tabular-nums .mono check
    const gutterBtn = page.locator('[data-testid^="debug-gutter-"]').nth(1);
    await gutterBtn.click();
    await expect(page.locator('[data-testid^="debug-bp-item-"]')).toHaveCount(1, { timeout: 10_000 });
    await page.getByTestId('debug-mode-decomp').click();
    await expect(page.getByTestId('debug-disasm')).toBeVisible();
    await page.getByTestId('debug-mode-mixed').click();
    await expect(page.getByTestId('debug-disasm')).toBeVisible();
    await page.getByTestId('debug-mode-disasm').click();
    const pcFontVar = await page.locator('[data-reg="pc"] .reg-val').evaluate((el) => getComputedStyle(el).fontVariantNumeric);
    expect(pcFontVar).toContain('tabular-nums');

    // Memory SRAM jump + byte poke
    await page.getByTestId('debug-tab-memory').click();
    await page.getByTestId('debug-mem-sram').click();
    await expect(page.getByTestId('debug-memory-grid')).toBeVisible({ timeout: 10_000 });
    await page.locator('[data-mem-offset="0"]').click();
    const pokeInput = page.getByTestId('debug-mem-poke-input');
    await pokeInput.fill('5a');
    await pokeInput.press('Enter');
    await expect(page.locator('[data-mem-offset="0"]')).toContainText('5a', { timeout: 10_000 });
    await auditBothViewports(page, 'debug-blink-memory');

    // Vim j/k/gg navigation in code viewport
    await page.getByTestId('statusbar-vim').click();
    await expect(page.getByTestId('debug-vim-strip')).toContainText('Ln 1, Col 1');
    await page.getByTestId('debug-code-viewport').click();
    await page.keyboard.press('j');
    await expect(page.getByTestId('debug-vim-strip')).toContainText('Ln 2,');
    await page.keyboard.press('g');
    await page.keyboard.press('g');
    await expect(page.getByTestId('debug-vim-strip')).toContainText('Ln 1,');
  });

  test('inspects DWARF uart_irq_echo.elf frames, steps, adds watch, and passes Editorial Slate audit', async ({ page }) => {
    server = await startServeFixture('tests/fixtures/uart/uart_irq_echo.elf');
    await connectAndOpenDebug(page, server.wsUrl);

    const pcRow = page.locator('[data-reg="pc"]');
    const beforePc = await pcRow.innerText();
    await page.getByTestId('debug-step-btn').click();
    await expect(pcRow).not.toHaveText(beforePc, { timeout: 10_000 });

    await expect(page.getByTestId('debug-frame-0')).toBeVisible({ timeout: 10_000 });
    await page.getByTestId('debug-frame-0').click();
    await page.getByTestId('debug-mode-source').click();
    await expect(page.getByTestId('debug-disasm')).toBeVisible();
    await page.getByTestId('debug-mode-disasm').click();

    await page.getByTestId('debug-watch-input').fill('pc');
    await page.getByTestId('debug-watch-add-btn').click();
    await expect(page.getByTestId('debug-watch-row-pc')).toContainText(/0x[0-9a-f]{8}/);

    await auditBothViewports(page, 'debug-uart-dwarf');
  });
});
