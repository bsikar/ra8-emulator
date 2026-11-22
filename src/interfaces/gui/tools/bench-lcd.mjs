import { chromium } from '@playwright/test';
import {
  PWA_DIST_DIR,
  installGlcdcAnimGuest,
  readGuestState,
  resolveEmulatorBinary,
  startServedElf,
  startStaticPwaServer,
  startTcpRelay,
} from './glcdc-anim-fixture.mjs';

const BENCH_MODES = [
  { mode: 'slow_0_1x', label: '0.1x', runMs: 950, periodCycles: 10_000_000 },
  { mode: 'rate_1x', label: '1x', runMs: 850, periodCycles: 16_000_000 },
  { mode: 'rate_100x', label: '100x', runMs: 950, periodCycles: 10_000_000 },
  { mode: 'rate_max', label: 'max', runMs: 950, periodCycles: 10_000_000 },
];

async function readCountersAndPaint(page) {
  return page.evaluate(() => {
    const txt = document.querySelector('[data-testid="hardware-lcd-counters"]')?.textContent ?? '';
    const cap = /Captured:\s*(\d+)/.exec(txt)?.[1] ?? '0';
    const skip = /Skipped:\s*(\d+)/.exec(txt)?.[1] ?? '0';
    const canvas = document.querySelector('[data-testid="hardware-lcd-canvas"]');
    const paints = Number.parseInt(canvas?.dataset['paintCount'] ?? '0', 10);
    return { captured: Number.parseInt(cap, 10), skipped: Number.parseInt(skip, 10), paints };
  });
}

async function readCanvasCenterLuma(page) {
  return page.evaluate(() => {
    const canvas = document.querySelector('[data-testid="hardware-lcd-canvas"]');
    const ctx = canvas?.getContext('2d');
    if (!canvas || !ctx || canvas.width === 0 || canvas.height === 0) return -1;
    const x = Math.floor(canvas.width / 2);
    const y = Math.floor(canvas.height / 2);
    const data = ctx.getImageData(x, y, 1, 1).data;
    return Math.round(((data[0] ?? 0) * 299 + (data[1] ?? 0) * 587 + (data[2] ?? 0) * 114) / 1000);
  });
}

async function verifyScrubberFrames(page, capturedCount) {
  if (capturedCount < 2) {
    throw new Error(`Scrubber verification requires >= 2 captured frames, got ${capturedCount}`);
  }
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
  const lastStatus = (await page.getByTestId('hardware-frame-scrubber').locator('..').textContent()) ?? '';
  const lastLuma = await readCanvasCenterLuma(page);
  await page.evaluate(() => {
    const el = document.querySelector('[data-testid="hardware-frame-scrubber"]');
    if (!(el instanceof HTMLInputElement)) throw new Error('Missing frame scrubber input');
    el.value = '0';
    el.dispatchEvent(new Event('input', { bubbles: true }));
  });
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
  await page.waitForTimeout(80);
  const firstStatus = (await page.getByTestId('hardware-frame-scrubber').locator('..').textContent()) ?? '';
  const firstLuma = await readCanvasCenterLuma(page);
  await page.getByTestId('hardware-live-btn').click();
  if (!firstStatus.includes('#1/')) {
    throw new Error(`Scrubber did not move to #1/: ${firstStatus}`);
  }
  if (firstLuma === lastLuma) {
    throw new Error(`Scrubber frame pixels did not change between first (${firstLuma}) and last (${lastLuma})`);
  }
  return { firstStatus: firstStatus.trim(), lastStatus: lastStatus.trim(), firstLuma, lastLuma };
}

async function runSingleMode(browser, pwaUrl, binPath, cfg, remoteRttMs) {
  const served = await startServedElf(binPath, 'tests/fixtures/gpio/blink.elf');
  const relay = remoteRttMs > 0 ? await startTcpRelay(served.port, Math.floor(remoteRttMs / 2)) : null;
  const targetWs = relay ? relay.wsUrl : served.wsUrl;
  let context = null;
  try {
    await installGlcdcAnimGuest(served.wsUrl, cfg.periodCycles);
    context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await context.newPage();
    await page.goto(`${pwaUrl}/launch?ws=${encodeURIComponent(targetWs)}`, { waitUntil: 'domcontentloaded' });
    await page.getByTestId('statusbar-connection-btn').waitFor({ state: 'visible', timeout: 10_000 });
    await page.waitForFunction(
      () => document.querySelector('[data-testid="statusbar-connection-btn"]')?.textContent?.includes('127.0.0.1'),
      { timeout: 10_000 }
    );
    await page.getByTestId('nav-hardware').click();
    await page.getByTestId('hardware-lcd-rate').selectOption(cfg.mode);
    await page.waitForTimeout(180);

    const baseCounts = await readCountersAndPaint(page);
    const t0 = performance.now();
    await page.getByTestId('topbar-run-toggle').click();
    await page.waitForTimeout(cfg.runMs);
    const toggle = page.getByTestId('topbar-run-toggle');
    if ((await toggle.textContent())?.trim() === 'Pause') {
      await toggle.click();
    }
    await page.waitForFunction(
      () => document.querySelector('[data-testid="topbar-run-toggle"]')?.textContent?.trim() === 'Continue',
      { timeout: 10_000 }
    );
    const actualRunMs = Math.max(1, performance.now() - t0);
    await page.waitForTimeout(200);

    const endCounts = await readCountersAndPaint(page);
    const captured = endCounts.captured - baseCounts.captured;
    const skipped = endCounts.skipped - baseCounts.skipped;
    const paints = Math.max(0, endCounts.paints - baseCounts.paints);
    const paintHz = Number(((paints * 1000) / actualRunMs).toFixed(1));
    const scrubber = cfg.mode === 'slow_0_1x' ? await verifyScrubberFrames(page, captured) : null;

    await context.close();
    context = null;
    await new Promise((r) => setTimeout(r, 50));

    const guest = await readGuestState(served.wsUrl);
    const drawnFrames = Math.max(1, guest.guestFrames - 1);
    if (cfg.mode === 'slow_0_1x') {
      if (captured < 5 || skipped !== 0 || Math.abs(captured - drawnFrames) > 1) {
        throw new Error(
          `Slow-motion frame fidelity check failed (link=${remoteRttMs}ms): captured=${captured}, skipped=${skipped}, drawn=${drawnFrames}`
        );
      }
    } else if ((cfg.mode === 'rate_100x' || cfg.mode === 'rate_max') && paintHz > 75) {
      throw new Error(`rAF cap exceeded display refresh at ${cfg.label}: paintHz=${paintHz}`);
    }

    return {
      mode: cfg.label,
      link: remoteRttMs > 0 ? `remote_${remoteRttMs}ms_rtt` : 'local_ws',
      runMs: Math.round(actualRunMs),
      captured,
      skipped,
      drawnFrames,
      guestFrames: guest.guestFrames,
      paints,
      paintHz,
      virtualTimeMs: Number((Number(guest.virtualNs) / 1_000_000).toFixed(2)),
      serveCpuPct: guest.metrics.hostCpuPercent,
      serveRssMb: guest.metrics.hostRssMb,
      scrubber,
    };
  } finally {
    if (context) await context.close();
    if (relay) await relay.close();
    await served.stop();
  }
}

export async function runLcdBench() {
  const binPath = resolveEmulatorBinary();
  const pwa = await startStaticPwaServer(PWA_DIST_DIR);
  const browser = await chromium.launch({ headless: true });
  const results = [];
  try {
    for (const remoteRttMs of [0, 30]) {
      for (const cfg of BENCH_MODES) {
        results.push(await runSingleMode(browser, pwa.url, binPath, cfg, remoteRttMs));
      }
    }
    console.log(JSON.stringify({ platform: process.platform, arch: process.arch, results }, null, 2));
    return results;
  } finally {
    await browser.close();
    await pwa.close();
  }
}

const isEntrypoint = process.argv[1] && process.argv[1].endsWith('bench-lcd.mjs');
if (isEntrypoint) {
  runLcdBench().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
