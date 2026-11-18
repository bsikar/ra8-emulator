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

test.describe('Per-Core Profiler (/profile) with Folded Stacks & Telemetry', () => {
  let server: ServedEmulatorHandle | null = null;

  test.afterEach(async () => {
    if (server) {
      await server.stop();
      server = null;
    }
  });

  test('captures folded stacks and metrics on call_tree.elf, exercises timeline/hotspots/export, and audits Editorial Slate', async ({ page }) => {
    server = await startServeFixture('tests/fixtures/profile/call_tree.elf', ['--profile-folded']);
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto(`/launch?ws=${encodeURIComponent(server.wsUrl)}`);
    await expect(page.getByTestId('statusbar-connection-btn')).toContainText('127.0.0.1', { timeout: 10_000 });

    await page.getByTestId('topbar-run-toggle').click();
    await page.waitForTimeout(250);
    await page.getByTestId('topbar-run-toggle').click();
    await expect(page.getByTestId('topbar-step')).toBeEnabled({ timeout: 10_000 });

    await page.getByTestId('nav-profile').click();
    await expect(page).toHaveURL(/\/profile$/);
    await expect(page.locator('body')).toContainText('METRICS & STACKS');
    await expect(page.locator('body')).toContainText('Host Memory RSS', { timeout: 10_000 });
    await expect(page.getByTestId('profile-cpu-sparkline')).toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId('profile-rss-sparkline')).toBeVisible({ timeout: 10_000 });

    await page.getByTestId('profile-capture-all-btn').click();
    await expect(page.getByTestId('profile-selected-frame')).toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId('profile-hotspots-table')).toContainText('heavy', { timeout: 10_000 });

    await page.getByTestId('sort-symbol').click();
    await page.getByTestId('profile-mode-icicle').click();
    await expect(page.getByTestId('profile-mode-icicle')).toHaveClass(/is-active/);
    await page.getByTestId('profile-mode-flame').click();

    await page.getByTestId('timeline-zoom-in').click();
    await page.getByTestId('timeline-mode-pan').click();
    await page.getByTestId('timeline-mode-brush').click();
    await page.getByTestId('timeline-reset-btn').click();

    await page.getByTestId('profile-core-both').click();
    await page.getByTestId('profile-core-cpu0').click();

    await page.getByTestId('profile-symbol-filter').fill('heavy');
    await expect(page.getByTestId('profile-hotspots-table')).toContainText('heavy');
    await page.getByTestId('profile-symbol-filter').fill('');

    await auditBothViewports(page, 'profile-calltree');

    const [download] = await Promise.all([
      page.waitForEvent('download'),
      page.getByTestId('profile-export-folded-btn').click(),
    ]);
    expect(download.suggestedFilename()).toContain('.folded');

    await page.getByTestId('hotspot-jump-heavy').click();
    await expect(page).toHaveURL(/\/debug/);
    await expect(page.locator('body')).toContainText('CORE REGISTERS');
  });
});
