import { execFileSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { CAP_TRANSPORT, Core, RA8RpcClient, StopReason, Topic } from '../client/dist/index.js';

const GUI_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const REPO_ROOT = path.resolve(GUI_DIR, '..', '..', '..');
const SOAK_SLICE_NS = 16_000_000n;
const SOAK_BUDGET_INSTR = 500_000n;

export function parseDurationMs(argv) {
  const idx = argv.indexOf('--duration-ms');
  if (idx >= 0 && argv[idx + 1]) {
    const val = Number.parseInt(argv[idx + 1], 10);
    if (Number.isFinite(val) && val > 0) return val;
  }
  return 5000;
}

export function percentile(sorted, p) {
  if (sorted.length === 0) return 0;
  const idx = Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * p));
  return sorted[idx] ?? 0;
}

export function summarizeSoakRun(input) {
  const sorted = [...input.latenciesMs].sort((a, b) => a - b);
  const virtMs = Number(input.endVirtualNs - input.startVirtualNs) / 1_000_000;
  const wallSec = Math.max(0.001, input.elapsedMs / 1000);
  const pacingRatio = virtMs / (wallSec * 1000);
  const heapDeltaMb = (input.endHeapBytes - input.startHeapBytes) / (1024 * 1024);
  return {
    durationMs: input.durationMs,
    elapsedMs: Math.round(input.elapsedMs),
    ops: sorted.length,
    p50Ms: Number(percentile(sorted, 0.5).toFixed(2)),
    p95Ms: Number(percentile(sorted, 0.95).toFixed(2)),
    p99Ms: Number(percentile(sorted, 0.99).toFixed(2)),
    virtualTimeMs: Number(virtMs.toFixed(2)),
    pacingRatio: Number(pacingRatio.toFixed(2)),
    maxCpuPct: input.maxCpuPct,
    maxRssMb: input.maxRssMb,
    heapDeltaMb: Number(heapDeltaMb.toFixed(2)),
    foldedBytes: input.foldedBytes,
  };
}

function resolveEmulatorBinary() {
  const envBin = process.env.RA8_EMULATOR_BIN;
  if (envBin && fs.existsSync(envBin)) return envBin;
  const binName = process.platform === 'win32' ? 'ra8_emulator.exe' : 'ra8_emulator';
  const localBin = path.join(REPO_ROOT, 'zig-out', 'bin', binName);
  if (fs.existsSync(localBin)) return localBin;
  try {
    const common = execFileSync('git', ['rev-parse', '--git-common-dir'], { cwd: REPO_ROOT, encoding: 'utf8' }).trim();
    const shared = path.join(path.resolve(REPO_ROOT, common, '..'), 'zig-out', 'bin', binName);
    if (fs.existsSync(shared)) return shared;
  } catch (err) {
    throw new Error(`Missing emulator binary: ${err instanceof Error ? err.message : String(err)}`);
  }
  throw new Error(`Missing emulator binary at ${localBin}`);
}

function startServedElf(binPath, elfPath) {
  return new Promise((resolve, reject) => {
    const proc = spawn(binPath, ['serve', '--profile-folded', '--listen', 'tcp:127.0.0.1:0', elfPath], {
      cwd: REPO_ROOT,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let stderr = '';
    const timer = setTimeout(() => {
      proc.kill();
      reject(new Error(`Serve startup timed out:\n${stderr}`));
    }, 10_000);

    proc.stderr?.on('data', (chunk) => {
      stderr += chunk.toString();
      const match = /serve:\s+listening on tcp:127\.0\.0\.1:(\d+)/.exec(stderr);
      if (match?.[1]) {
        clearTimeout(timer);
        resolve({ proc, wsUrl: `ws://127.0.0.1:${match[1]}` });
      }
    });
    proc.once('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
}

function stopChild(proc) {
  return new Promise((resolve) => {
    if (proc.killed || proc.exitCode !== null) {
      resolve();
      return;
    }
    proc.once('exit', () => resolve());
    proc.kill();
    setTimeout(() => resolve(), 1500);
  });
}

async function pumpSoakRunner(client, useTransport, state) {
  if (!state.active || state.inFlight) {
    if (state.active) state.pending = true;
    return;
  }
  state.inFlight = true;
  state.pending = false;
  try {
    if (useTransport) await client.advanceAsync(Core.Cpu0, SOAK_SLICE_NS);
    else await client.continueRun(Core.Cpu0, SOAK_BUDGET_INSTR);
  } catch (err) {
    if (state.active) throw err;
  } finally {
    state.inFlight = false;
    if (state.active && state.pending) {
      queueMicrotask(() => void pumpSoakRunner(client, useTransport, state));
    }
  }
}

async function sampleSoakLoop(client, durationMs) {
  const latenciesMs = [];
  let maxRssMb = 0;
  let maxCpuPct = 0;
  let foldedBytes = 0;
  const deadline = Date.now() + durationMs;
  while (Date.now() < deadline) {
    const t0 = performance.now();
    const [metrics, stack, folded] = await Promise.all([
      client.getMetrics(),
      client.getStackReport(Core.Cpu0),
      client.getFolded(Core.Cpu0),
    ]);
    latenciesMs.push(performance.now() - t0);
    if (!Number.isFinite(metrics.hostRssMb) || !Number.isFinite(metrics.hostCpuPercent) || !Number.isFinite(stack.msp)) {
      throw new Error('Invalid metrics or stack report frame received during soak');
    }
    maxRssMb = Math.max(maxRssMb, metrics.hostRssMb);
    maxCpuPct = Math.max(maxCpuPct, metrics.hostCpuPercent);
    foldedBytes = Math.max(foldedBytes, folded.length);
    await new Promise((r) => setTimeout(r, 40));
  }
  return { latenciesMs, maxRssMb, maxCpuPct, foldedBytes };
}

export async function runSoak(argv = process.argv.slice(2)) {
  const durationMs = parseDurationMs(argv);
  const binPath = resolveEmulatorBinary();
  const elfPath = path.join(REPO_ROOT, 'tests', 'fixtures', 'profile', 'call_tree.elf');
  const { proc, wsUrl } = await startServedElf(binPath, elfPath);
  const client = new RA8RpcClient();
  const state = { active: true, inFlight: false, pending: false };

  try {
    const hello = await client.connect(wsUrl);
    const useTransport = (hello.caps & CAP_TRANSPORT) !== 0;
    await client.subscribe(Core.Cpu0, Topic.Stop);
    if (useTransport) await client.subscribe(Core.Cpu0, Topic.Transport);
    await client.setSpeed(Core.Cpu0, 0n);

    client.on('stop', (evt) => {
      if (evt.reason === StopReason.Count && state.active) void pumpSoakRunner(client, useTransport, state);
    });
    client.on('transport', (evt) => {
      if (evt.finished && evt.reason === StopReason.Count && state.active) void pumpSoakRunner(client, useTransport, state);
    });

    const startVirtualNs = await client.now(Core.Cpu0);
    const startHeapBytes = process.memoryUsage().heapUsed;
    const tStart = performance.now();
    await pumpSoakRunner(client, useTransport, state);
    const sampled = await sampleSoakLoop(client, durationMs);

    state.active = false;
    try {
      await client.interrupt(Core.Cpu0);
    } catch (err) {
      void err;
    }
    await client.pause(Core.Cpu0);
    const endVirtualNs = await client.now(Core.Cpu0);
    const elapsedMs = performance.now() - tStart;
    const endHeapBytes = process.memoryUsage().heapUsed;
    if (sampled.latenciesMs.length === 0) throw new Error('Soak loop recorded zero telemetry samples');

    const summary = summarizeSoakRun({
      durationMs,
      elapsedMs,
      latenciesMs: sampled.latenciesMs,
      startVirtualNs,
      endVirtualNs,
      maxCpuPct: sampled.maxCpuPct,
      maxRssMb: sampled.maxRssMb,
      startHeapBytes,
      endHeapBytes,
      foldedBytes: sampled.foldedBytes,
    });
    console.log(JSON.stringify(summary));
    return summary;
  } finally {
    state.active = false;
    client.disconnect();
    await stopChild(proc);
  }
}

const isEntrypoint = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isEntrypoint) {
  runSoak().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
