import { expect, test } from '@playwright/test';
import { auditEditorialSlateScreen } from './helpers/editorial-slate-audit';

test.describe('Editorial Slate Shell CUJ', () => {
  test('renders anonymous Editorial Slate chrome with zero overlaps across lazy routes', async ({ page }) => {
    await page.goto('/launch');
    await expect(page.getByRole('heading', { name: 'Connect Target Session' })).toBeVisible();
    await auditEditorialSlateScreen(page, 'launch');

    const routes = [
      { testId: 'nav-debug', expectedText: 'CORE REGISTERS', url: '/debug' },
      { testId: 'nav-hardware', expectedText: 'FITTED PARTS', url: '/hardware' },
      { testId: 'nav-rewind', expectedText: 'EXECUTION BRANCHES', url: '/rewind' },
      { testId: 'nav-profile', expectedText: 'METRICS & STACKS', url: '/profile' },
      { testId: 'nav-console', expectedText: 'UART SERIAL STREAM', url: '/console' },
    ];

    for (const route of routes) {
      await page.getByTestId(route.testId).click();
      await expect(page).toHaveURL(new RegExp(`${route.url}$`));
      await expect(page.getByText(route.expectedText)).toBeVisible();
      await auditEditorialSlateScreen(page, route.url);
    }
  });

  test('supports Cmd/Ctrl+K Command Mode keyboard CUJ and input-safe shortcuts', async ({ page }) => {
    await page.goto('/launch');
    const wsInput = page.getByTestId('launch-ws-input');
    await wsInput.click();
    await wsInput.fill('ws://127.0.0.1:4567');

    // F10 inside an input must not trigger execution shortcut or swallow keystrokes
    await page.keyboard.press('F10');
    await expect(wsInput).toHaveValue('ws://127.0.0.1:4567');

    // Open Command Mode with ControlOrMeta+k even from inside input
    await page.keyboard.press('ControlOrMeta+k');
    const palette = page.getByTestId('command-palette');
    await expect(palette).toBeVisible();
    await auditEditorialSlateScreen(page, 'command-palette');

    const paletteInput = page.getByTestId('command-palette-input');
    await paletteInput.fill('debug');
    await page.keyboard.press('Enter');

    await expect(palette).toBeHidden();
    await expect(page).toHaveURL(/\/debug$/);
    await auditEditorialSlateScreen(page, 'post-command-debug');
  });

  test('opens settings sheet cleanly from statusbar gear', async ({ page }) => {
    await page.goto('/launch');
    await page.getByTestId('settings-trigger').click();
    await expect(page.getByRole('dialog', { name: 'Session settings' })).toBeVisible();
    await auditEditorialSlateScreen(page, 'settings-sheet');
    await page.keyboard.press('Escape');
    await expect(page.getByRole('dialog', { name: 'Session settings' })).toBeHidden();
  });
});
