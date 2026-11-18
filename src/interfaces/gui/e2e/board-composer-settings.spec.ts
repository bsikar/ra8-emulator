import { expect, test } from '@playwright/test';
import { auditEditorialSlateScreen } from './helpers/editorial-slate-audit';
import { startServeFixture, type ServedEmulatorHandle } from './helpers/serve-fixture';

test.describe('Custom Board Composer, Settings Schemes, Splits & Fullscreen', () => {
  let served: ServedEmulatorHandle;

  test.beforeAll(async () => {
    served = await startServeFixture('tests/fixtures/gpio/blink.elf');
  });

  test.afterAll(async () => {
    await served?.stop();
  });

  test('Custom Board Composer: composes multi-MCU custom board, audits all sub-modals, and persists .board', async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto('/workspace/new');
    await page.getByTestId('new-ws-create-board-btn').click();
    await expect(page.getByTestId('board-composer-modal')).toBeVisible();

    for (const vp of [
      { width: 1440, height: 900 },
      { width: 1280, height: 720 },
    ]) {
      await page.setViewportSize(vp);
      await auditEditorialSlateScreen(page, `board-composer-${vp.width}x${vp.height}`);
    }
    await page.setViewportSize({ width: 1440, height: 900 });

    // Configure Cores
    await page.getByTestId('composer-edit-mcu-U1').click();
    await expect(page.getByTestId('composer-cores-modal')).toBeVisible();
    await auditEditorialSlateScreen(page, 'board-composer-cores-1440x900');
    await page.getByTestId('cores-apply-btn').click();

    // Add Preset MCU & Custom Silicon (with On-Chip Memory Map)
    await page.getByTestId('composer-open-preset-mcu').click();
    await expect(page.getByTestId('composer-preset-mcu-modal')).toBeVisible();
    await auditEditorialSlateScreen(page, 'board-composer-preset-mcu-1440x900');
    await page.getByTestId('switch-to-custom-silicon').click();
    await expect(page.getByTestId('composer-custom-silicon-modal')).toBeVisible();
    await expect(page.getByTestId('custom-silicon-add-onchip-btn')).toBeVisible();
    await auditEditorialSlateScreen(page, 'board-composer-custom-silicon-1440x900');
    await page.getByTestId('custom-silicon-submit').click();
    await expect(page.getByTestId('composer-mcu-row-U2')).toBeVisible();

    // Add Memory Region
    await page.getByTestId('composer-open-add-memory').click();
    await expect(page.getByTestId('composer-memory-modal')).toBeVisible();
    await auditEditorialSlateScreen(page, 'board-composer-memory-1440x900');
    await page.getByTestId('memory-submit-btn').click();

    // Component Catalog (Host Frame Source & Pin Mapping) & Custom Component
    await page.getByTestId('composer-open-add-component').click();
    await expect(page.getByTestId('composer-add-component-modal')).toBeVisible();
    await expect(page.getByTestId('catalog-comp-frame-source')).toBeVisible();
    await auditEditorialSlateScreen(page, 'board-composer-add-comp-1440x900');
    await page.getByTestId('switch-to-custom-component').click();
    await expect(page.getByTestId('composer-custom-component-modal')).toBeVisible();
    await auditEditorialSlateScreen(page, 'board-composer-custom-comp-1440x900');
    await page.getByTestId('custom-comp-submit').click();

    await page.getByTestId('composer-board-name').fill('Dual-MCU Motor Carrier');
    await page.getByTestId('composer-profile-file').fill('dual_mcu_motor.board');

    const downloadPromise = page.waitForEvent('download');
    await page.getByTestId('composer-export-btn').click();
    const download = await downloadPromise;
    expect(download.suggestedFilename()).toBe('dual_mcu_motor.board');

    await page.getByTestId('composer-save-btn').click();
    await expect(page.getByTestId('board-composer-modal')).toBeHidden();
    await expect(page.getByTestId('new-workspace-dialog')).toContainText('DUAL-MCU-MOTOR');

    await page.reload();
    await expect(page.getByTestId('preset-dual-mcu-motor')).toBeVisible();
  });

  test('Settings Modal: updates code-buffer scheme vars without altering chrome, rescans probes, and triggers View > Full Screen', async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto(`/launch?ws=${encodeURIComponent(served.wsUrl)}`);
    await expect(page.getByTestId('statusbar-connection-btn')).toContainText('127.0.0.1');

    await page.getByTestId('settings-trigger').click();
    const dialog = page.getByRole('dialog', { name: 'Session settings' });
    await expect(dialog).toBeVisible();
    await expect(page.getByTestId('settings-vim-toggle')).toBeVisible();
    await expect(page.getByTestId('settings-open-extensions')).toBeVisible();

    await page.getByTestId('settings-tab-appearance').click();
    await page.getByTestId('scheme-option-tokyo-slate').click();
    for (const vp of [
      { width: 1440, height: 900 },
      { width: 1280, height: 720 },
    ]) {
      await page.setViewportSize(vp);
      await auditEditorialSlateScreen(page, `settings-schemes-${vp.width}x${vp.height}`);
    }

    const tokKw = await page.evaluate(() => document.documentElement.style.getPropertyValue('--es-tok-kw'));
    expect(tokKw).toBe('#9d8ec7');

    await page.setViewportSize({ width: 1440, height: 900 });
    await page.getByTestId('settings-tab-probes').click();
    await page.getByTestId('settings-rescan-probes').click();
    await auditEditorialSlateScreen(page, 'settings-probes-1440x900');

    await page.getByTestId('settings-save-btn').click();
    await expect(dialog).toBeHidden();

    // Verify View > Full Screen menu command & SplitPane keyboard resize on /debug
    await page.getByTestId('menu-view').click();
    await expect(page.getByTestId('menuitem-nav-fullscreen')).toBeVisible();
    await page.getByTestId('menuitem-nav-fullscreen').click();

    await page.getByTestId('nav-debug').click();
    const handle = page.getByTestId('split-pane-handle').first();
    await expect(handle).toBeVisible();
    await handle.focus();
    await page.keyboard.press('ArrowRight');
    await auditEditorialSlateScreen(page, 'split-pane-resized');
  });
});
