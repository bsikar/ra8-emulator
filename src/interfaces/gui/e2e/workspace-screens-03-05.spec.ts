import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { expect, test, type Page } from '@playwright/test';
import { auditEditorialSlateScreen } from './helpers/editorial-slate-audit';
import { startServeFixture, type ServedEmulatorHandle } from './helpers/serve-fixture';

const ARTIFACT_DIR =
  process.env['RA8_M3_SCREENSHOT_DIR'] || path.resolve(process.cwd(), 'test-results', 'screenshots');

function saveM3Shot(page: Page, name: string): Promise<Buffer> {
  fs.mkdirSync(ARTIFACT_DIR, { recursive: true });
  return page.screenshot({ path: path.join(ARTIFACT_DIR, name) });
}

test.describe('Milestone 3: Screens 03, 04/04a & 05 with Live Backend RPC', () => {
  let served: ServedEmulatorHandle;
  let tempRoot = '';
  let tempWorkspace = '';
  let tempArtifacts = '';

  test.beforeAll(async () => {
    tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ra8-m3-'));
    tempWorkspace = path.join(tempRoot, 'workspace');
    tempArtifacts = path.join(tempRoot, 'artifacts');
    fs.mkdirSync(tempWorkspace, { recursive: true });
    fs.mkdirSync(tempArtifacts, { recursive: true });

    const repoRoot = path.resolve(process.cwd(), '..', '..', '..');
    const blinkPath = path.join(repoRoot, 'tests', 'fixtures', 'gpio', 'blink.elf');
    const blinkBytes = fs.readFileSync(blinkPath);
    fs.writeFileSync(path.join(tempWorkspace, 'blink.elf'), blinkBytes);
    const largeBytes = Buffer.concat([blinkBytes, Buffer.alloc(Math.max(0, 80_000 - blinkBytes.length))]);
    fs.writeFileSync(path.join(tempWorkspace, 'large_firmware.elf'), largeBytes);
    fs.writeFileSync(path.join(tempWorkspace, 'not_an_elf.bin'), Buffer.from('NOT AN ELF FILE\n'));

    served = await startServeFixture(undefined, ['--workspace', tempWorkspace, '--artifacts-root', tempArtifacts]);
  });

  test.afterAll(async () => {
    await served?.stop();
    if (tempRoot && fs.existsSync(tempRoot)) {
      fs.rmSync(tempRoot, { recursive: true, force: true });
    }
  });

  test('Screen 03 (/import): exports live session .tar, verifies USTAR manifest, rejects corrupt bundle, and imports', async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto('/import');
    await expect(page.getByTestId('import-empty-staged')).toBeVisible();
    await auditEditorialSlateScreen(page, 'screen03-empty-1440x900');

    await page.setViewportSize({ width: 1280, height: 720 });
    await auditEditorialSlateScreen(page, 'screen03-empty-1280x720');
    await page.setViewportSize({ width: 1440, height: 900 });

    await page.goto(`/launch?ws=${encodeURIComponent(served.wsUrl)}`);
    await expect(page.getByTestId('statusbar-connection-btn')).toContainText('127.0.0.1');
    await page.getByTestId('launch-action-import').click();
    await expect(page).toHaveURL(/\/import$/);

    await page.getByTestId('import-export-btn').click();
    await expect(page.getByTestId('import-staged-summary')).toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId('import-admission-status')).toContainText('ADMISSION VERIFIED');
    await auditEditorialSlateScreen(page, 'screen03-verified-1440x900');
    await saveM3Shot(page, 'm3_01_import_bundle.png');

    await page.setViewportSize({ width: 1280, height: 720 });
    await auditEditorialSlateScreen(page, 'screen03-verified-1280x720');
    await page.setViewportSize({ width: 1440, height: 900 });

    await page.getByTestId('import-file-input').setInputFiles({
      name: 'corrupt.tar',
      mimeType: 'application/x-tar',
      buffer: Buffer.from([0xde, 0xad, 0xbe, 0xef]),
    });
    await expect(page.getByTestId('import-error')).toBeVisible();
    await expect(page.getByTestId('import-admission-status')).toContainText('INVALID ARCHIVE');

    await page.getByTestId('import-export-btn').click();
    await expect(page.getByTestId('import-submit-btn')).toBeEnabled();
    await page.getByTestId('import-submit-btn').click();
    await expect(page).toHaveURL(/\/rewind$/, { timeout: 10_000 });
  });

  test('Screen 04 & 04a (/workspace/new & Board Details Modal): inspects EK-RA8P1 spec and duplicates profile', async ({ page }) => {
    for (const vp of [
      { width: 1440, height: 900 },
      { width: 1280, height: 720 },
    ]) {
      await page.setViewportSize(vp);
      await page.goto('/workspace/new');
      await expect(page.getByTestId('new-workspace-dialog')).toBeVisible();
      await auditEditorialSlateScreen(page, `screen04-new-ws-${vp.width}x${vp.height}`);
    }

    await page.setViewportSize({ width: 1440, height: 900 });
    await page.getByTestId('board-details-btn-ra8p1').click();
    const modal = page.getByTestId('board-details-modal');
    await expect(modal).toBeVisible();
    await expect(modal).toContainText('R7KA8P1KFLCAC');
    await expect(modal).toContainText('Ethos-U55');
    await expect(modal).toContainText('0x8000_0000');
    await expect(modal).toContainText('0x9000_0000');
    await auditEditorialSlateScreen(page, 'screen04a-board-details-1440x900');
    await saveM3Shot(page, 'm3_02_new_workspace_and_details.png');

    await page.getByTestId('board-details-duplicate-btn').click();
    await expect(modal).toBeHidden();
    await expect(page.getByTestId('new-workspace-dialog')).toContainText('Custom');
  });

  test('Screen 05 (/open): browses remote --workspace dir, rejects bad ELF, uploads >64 KiB chunked ELF to /debug', async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto(`/launch?ws=${encodeURIComponent(served.wsUrl)}`);
    await expect(page.getByTestId('statusbar-connection-btn')).toContainText('127.0.0.1');
    await page.getByTestId('launch-action-open').click();
    await expect(page).toHaveURL(/\/open$/);

    await expect(page.getByTestId('open-entry-blink.elf')).toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId('open-entry-large_firmware.elf')).toBeVisible();
    await expect(page.getByTestId('open-entry-not_an_elf.bin')).toBeVisible();

    await page.getByTestId('open-entry-not_an_elf.bin').click();
    await expect(page.getByTestId('open-error-banner')).toBeVisible();
    await expect(page.getByTestId('statusbar-connection-btn')).toContainText('127.0.0.1');

    await page.getByTestId('open-entry-large_firmware.elf').click();
    await expect(page.getByTestId('open-elf-summary')).toBeVisible();
    await expect(page.getByTestId('open-elf-summary')).toContainText('Chunked CRC32');
    await auditEditorialSlateScreen(page, 'screen05-open-elf-1440x900');
    await saveM3Shot(page, 'm3_03_open_workspace_elf.png');

    await page.setViewportSize({ width: 1280, height: 720 });
    await auditEditorialSlateScreen(page, 'screen05-open-elf-1280x720');
    await page.setViewportSize({ width: 1440, height: 900 });

    await page.getByTestId('open-submit-btn').click();
    await expect(page).toHaveURL(/\/debug$/, { timeout: 10_000 });
    await expect(page).toHaveTitle('large_firmware.elf — RA8 Emulator');
    await expect(page.locator('[data-reg="pc"]')).toBeVisible();
    await auditEditorialSlateScreen(page, 'screen05-loaded-debug-1440x900');
    await saveM3Shot(page, 'm3_04_chunked_elf_loaded_debug.png');
  });
});
