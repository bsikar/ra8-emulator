import { execFile } from 'node:child_process';
import fs from 'node:fs';
import { promisify } from 'node:util';
import { chromium } from '@playwright/test';
import { Core, RA8RpcClient, Register } from '../client/dist/index.js';
import {
  PWA_DIST_DIR,
  REPO_ROOT,
  installGlcdcAnimGuest,
  resolveEmulatorBinary,
  startServedElf,
  startStaticPwaServer,
} from './glcdc-anim-fixture.mjs';

const execFileAsync = promisify(execFile);

function parseArgs(argv) {
  let durationMs = 1_800_000;
  let outPath = null;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--duration-ms' && argv[i + 1]) {
      const parsed = Number.parseInt(argv[i + 1], 10);
      if (Number.isFinite(parsed) && parsed > 0) durationMs = parsed;
    } else if (argv[i] === '--out' && argv[i + 1]) {
      outPath = argv[i + 1];
    }
  }
  return { durationMs, outPath };
}

function percentile(sorted, p) {
  if (sorted.length === 0) return 0;
  const idx = Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * p));
  return Number((sorted[idx] ?? 0).toFixed(2));
}

async function openConnectedPage(browser, pwaUrl, wsUrl, viewport) {
  const context = await browser.newContext({ viewport });
  const page = await context.newPage();
  await page.goto(`${pwaUrl}/launch?ws=${encodeURIComponent(wsUrl)}`, { waitUntil: 'domcontentloaded' });
  await page.waitForFunction(
    () => document.querySelector('[data-testid="statusbar-connection-btn"]')?.textContent?.includes('127.0.0.1'),
    { timeout: 10_000 }
  );
  return { context, page };
}

async function measureDemo1200ms(browser, pwaUrl, binPath) {
  const cliStart = performance.now();
  await execFileAsync(binPath, ['tests/fixtures/threadx/threadx_stkof.elf', '--ms', '1200'], { cwd: REPO_ROOT });
  const headlessCliMs = Number((performance.now() - cliStart).toFixed(2));

  const served = await startServedElf(binPath, 'tests/fixtures/threadx/threadx_stkof.elf');
  let context = null;
  try {
    const conn = await openConnectedPage(browser, pwaUrl, served.wsUrl, { width: 1280, height: 800 });
    context = conn.context;
    const { page } = conn;
    await page.getByTestId('nav-debug').click();

    const pwaStart = performance.now();
    await page.getByTestId('topbar-run-toggle').click();
    await page.waitForFunction(
      () => {
        const t = document.querySelector('[data-testid="statusbar-virtual-time"]')?.textContent ?? '';
        return /1\.\d+s\b/.test(t) || /([2-9]\d*|\d{2,})\.\d+s\b/.test(t);
      },
      { timeout: 15_000 }
    );
    const pwaRun1200Ms = Number((performance.now() - pwaStart).toFixed(2));

    const pauseStart = performance.now();
    if ((await page.getByTestId('topbar-run-toggle').textContent())?.trim() === 'Pause') {
      await page.getByTestId('topbar-run-toggle').click();
    }
    await page.waitForFunction(
      () => document.querySelector('[data-testid="topbar-run-toggle"]')?.textContent?.trim() === 'Continue',
      { timeout: 10_000 }
    );
    const pauseLatencyMs = Number((performance.now() - pauseStart).toFixed(2));

    const stepStart = performance.now();
    await page.getByTestId('topbar-step').click();
    await page.waitForFunction(
      () => !document.querySelector('[data-testid="topbar-step"]')?.hasAttribute('disabled'),
      { timeout: 10_000 }
    );
    const stepLatencyMs = Number((performance.now() - stepStart).toFixed(2));
    await context.close();
    context = null;
    await new Promise((r) => setTimeout(r, 50));

    const client = new RA8RpcClient();
    await client.connect(served.wsUrl);
    const virtualMs = Number((Number(await client.now(Core.Cpu0)) / 1_000_000).toFixed(2));
    client.disconnect();
    return { headlessCliMs, pwaRun1200Ms, pauseLatencyMs, stepLatencyMs, virtualMs };
  } finally {
    if (context) await context.close();
    await served.stop();
  }
}

async function measureMatrixCell(browser, pwaUrl, binPath, viewport, mode, cellMs) {
  const served = await startServedElf(binPath, 'tests/fixtures/gpio/blink.elf');
  let context = null;
  try {
    await installGlcdcAnimGuest(served.wsUrl, 10_000_000);
    const conn = await openConnectedPage(browser, pwaUrl, served.wsUrl, viewport);
    context = conn.context;
    const { page } = conn;
    await page.getByTestId('nav-hardware').click();
    await page.getByTestId('hardware-lcd-rate').selectOption(mode);
    await page.waitForTimeout(80);
    await page.evaluate(() => {
      const mem = /** @type {{ performance: Performance & { memory?: { usedJSHeapSize: number } } }} */ (window).performance.memory;
      window.__bench = {
        deltas: [],
        last: performance.now(),
        heapStart: mem ? mem.usedJSHeapSize : 0,
        active: true,
      };
      function tick(now) {
        if (!window.__bench.active) return;
        window.__bench.deltas.push(now - window.__bench.last);
        window.__bench.last = now;
        requestAnimationFrame(tick);
      }
      requestAnimationFrame(tick);
    });
    await page.getByTestId('topbar-run-toggle').click();
    await page.waitForTimeout(cellMs);
    if ((await page.getByTestId('topbar-run-toggle').textContent())?.trim() === 'Pause') {
      await page.getByTestId('topbar-run-toggle').click();
    }
    await page.waitForFunction(
      () => document.querySelector('[data-testid="topbar-run-toggle"]')?.textContent?.trim() === 'Continue',
      { timeout: 10_000 }
    );
    const browserStats = await page.evaluate(() => {
      window.__bench.active = false;
      const deltas = window.__bench.deltas.slice(1).sort((a, b) => a - b);
      const mem = window.performance.memory;
      const heapEnd = mem ? mem.usedJSHeapSize : 0;
      const dropped = deltas.filter((d) => d > 50).length;
      const heapDeltaMb = Number(((heapEnd - window.__bench.heapStart) / (1024 * 1024)).toFixed(2));
      return { deltas, dropped, heapDeltaMb };
    });
    await context.close();
    context = null;
    await new Promise((r) => setTimeout(r, 50));

    const client = new RA8RpcClient();
    await client.connect(served.wsUrl);
    const metrics = await client.getMetrics();
    const virtualMs = Number((Number(await client.now(Core.Cpu0)) / 1_000_000).toFixed(2));
    client.disconnect();
    return {
      viewport: `${viewport.width}x${viewport.height}`,
      mode,
      durationMs: cellMs,
      rafP50Ms: percentile(browserStats.deltas, 0.5),
      rafP99Ms: percentile(browserStats.deltas, 0.99),
      droppedFrames: browserStats.dropped,
      jsHeapDeltaMb: browserStats.heapDeltaMb,
      serveCpuPct: metrics.hostCpuPercent,
      serveRssMb: metrics.hostRssMb,
      virtualMs,
    };
  } finally {
    if (context) await context.close();
    await served.stop();
  }
}

async function measureSoak1e7(browser, pwaUrl, binPath) {
  const served = await startServedElf(binPath, 'tests/fixtures/profile/call_tree.elf', ['--profile-folded']);
  let context = null;
  try {
    const conn = await openConnectedPage(browser, pwaUrl, served.wsUrl, { width: 1440, height: 900 });
    context = conn.context;
    const { page } = conn;
    await page.getByTestId('nav-profile').click();
    const t0 = performance.now();
    await page.getByTestId('topbar-run-toggle').click();
    await page.waitForFunction(
      () => {
        const text = document.querySelector('[data-testid="statusbar-virtual-time"]')?.textContent ?? '';
        const m = /([\d.]+)\s*(ns|us|ms|s)/.exec(text);
        if (!m?.[1] || !m[2]) return false;
        const v = Number.parseFloat(m[1]);
        const ms = m[2] === 's' ? v * 1000 : m[2] === 'ms' ? v : 0;
        return ms >= 11;
      },
      { timeout: 15_000 }
    );
    if ((await page.getByTestId('topbar-run-toggle').textContent())?.trim() === 'Pause') {
      await page.getByTestId('topbar-run-toggle').click();
    }
    await page.waitForFunction(
      () => document.querySelector('[data-testid="topbar-run-toggle"]')?.textContent?.trim() === 'Continue',
      { timeout: 10_000 }
    );
    const wallMs = Number((performance.now() - t0).toFixed(2));
    await context.close();
    context = null;
    await new Promise((r) => setTimeout(r, 50));

    const client = new RA8RpcClient();
    await client.connect(served.wsUrl);
    const cycles = await client.now(Core.Cpu0);
    const metrics = await client.getMetrics();
    const folded = await client.getFolded(Core.Cpu0);
    client.disconnect();
    if (cycles < 10_000_000n) {
      throw new Error(`10^7 soak fell short: virtualNs=${cycles}`);
    }
    return {
      virtualCycles: cycles.toString(),
      wallMs,
      serveCpuPct: metrics.hostCpuPercent,
      serveRssMb: metrics.hostRssMb,
      foldedBytes: folded.length,
    };
  } finally {
    if (context) await context.close();
    await served.stop();
  }
}

async function readStopRegs(client) {
  return {
    virtualNs: (await client.now(Core.Cpu0)).toString(),
    pc: await client.readRegister(Core.Cpu0, Register.Pc),
    sp: await client.readRegister(Core.Cpu0, Register.Sp),
    r0: await client.readRegister(Core.Cpu0, Register.R0),
    r1: await client.readRegister(Core.Cpu0, Register.R1),
    r2: await client.readRegister(Core.Cpu0, Register.R2),
    r3: await client.readRegister(Core.Cpu0, Register.R3),
  };
}

async function measureZeroDivergence(browser, pwaUrl, binPath) {
  const refServed = await startServedElf(binPath, 'tests/fixtures/threadx/threadx_stkof.elf');
  const pwaServed = await startServedElf(binPath, 'tests/fixtures/threadx/threadx_stkof.elf');
  const targetNs = 5_000_000_000n;
  let context = null;
  try {
    const refClient = new RA8RpcClient();
    await refClient.connect(refServed.wsUrl);
    await refClient.advance(Core.Cpu0, targetNs);
    const ref = await readStopRegs(refClient);
    refClient.disconnect();

    const conn = await openConnectedPage(browser, pwaUrl, pwaServed.wsUrl, { width: 1280, height: 800 });
    context = conn.context;
    const { page } = conn;
    await page.getByTestId('nav-hardware').click();
    await page.getByTestId('hardware-lcd-rate').selectOption('slow_0_1x');
    await page.getByTestId('hardware-lcd-rate').selectOption('rate_1x');
    await page.waitForTimeout(80);
    await page.getByTestId('nav-debug').click();
    await page.getByTestId('topbar-run-toggle').click();
    await page.waitForTimeout(120);
    if ((await page.getByTestId('topbar-run-toggle').textContent())?.trim() === 'Pause') {
      await page.getByTestId('topbar-run-toggle').click();
    }
    await page.waitForFunction(
      () => document.querySelector('[data-testid="topbar-run-toggle"]')?.textContent?.trim() === 'Continue',
      { timeout: 10_000 }
    );
    const pwaTimeText = (await page.getByTestId('statusbar-virtual-time').textContent()) ?? '';
    await context.close();
    context = null;
    await new Promise((r) => setTimeout(r, 50));

    const pwaClient = new RA8RpcClient();
    await pwaClient.connect(pwaServed.wsUrl);
    const curNs = await pwaClient.now(Core.Cpu0);
    if (curNs >= targetNs) {
      throw new Error(`PWA overran target during interactive pause check: ${curNs} >= ${targetNs}`);
    }
    await pwaClient.advance(Core.Cpu0, targetNs - curNs);
    const pwa = await readStopRegs(pwaClient);
    pwaClient.disconnect();

    const mismatches = ['virtualNs', 'pc', 'sp', 'r0', 'r1', 'r2', 'r3'].filter((k) => ref[k] !== pwa[k]);
    if (mismatches.length > 0) {
      throw new Error(`Zero-divergence check failed on fields: ${mismatches.join(', ')}`);
    }
    return { pwaMidPauseLabel: pwaTimeText.trim(), ref, pwa, divergenceCount: 0 };
  } finally {
    if (context) await context.close();
    await refServed.stop();
    await pwaServed.stop();
  }
}

export async function runSustainedBench(argv = process.argv.slice(2)) {
  const { durationMs, outPath } = parseArgs(argv);
  const binPath = resolveEmulatorBinary();
  const pwa = await startStaticPwaServer(PWA_DIST_DIR);
  const browser = await chromium.launch({ headless: true });
  try {
    const demo1200ms = await measureDemo1200ms(browser, pwa.url, binPath);
    const cellMs = Math.max(800, Math.floor(durationMs / 6));
    const sustainedMatrix = [];
    for (const vp of [{ width: 1920, height: 1080 }, { width: 3840, height: 2160 }]) {
      for (const mode of ['rate_1x', 'rate_100x', 'rate_max']) {
        sustainedMatrix.push(await measureMatrixCell(browser, pwa.url, binPath, vp, mode, cellMs));
      }
    }
    const soak1e7 = await measureSoak1e7(browser, pwa.url, binPath);
    const zeroDivergence = await measureZeroDivergence(browser, pwa.url, binPath);
    const report = {
      platform: process.platform,
      arch: process.arch,
      requestedMatrixMs: durationMs,
      demo1200ms,
      sustainedMatrix,
      soak1e7,
      zeroDivergence,
    };
    const json = JSON.stringify(report, null, 2);
    if (outPath) fs.writeFileSync(outPath, json, 'utf8');
    console.log(json);
    return report;
  } finally {
    await browser.close();
    await pwa.close();
  }
}

const isEntrypoint = process.argv[1] && process.argv[1].endsWith('bench-sustained.mjs');
if (isEntrypoint) {
  runSustainedBench().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
