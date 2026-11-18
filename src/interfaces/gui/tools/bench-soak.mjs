import { execFileSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Core, RA8RpcClient } from '../client/dist/index.js';

const GUI_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const REPO_ROOT = path.resolve(GUI_DIR, '..', '..', '..');

function parseDurationMs(argv) {
  const idx = argv.indexOf('--duration-ms');
  if (idx >= 0 && argv[idx + 1]) {
    const val = Number.parseInt(argv[idx + 1], 10);
    if (Number.isFinite(val) && val > 0) return val;
  }
  return 5000;
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

function percentile(sorted, p) {
  if (sorted.length === 0) return 0;
  const idx = Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * p));
  return sorted[idx] ?? 0;
}

async function runSoak() {
  const durationMs = parseDurationMs(process.argv.slice(2));
  const binPath = resolveEmulatorBinary();
  const elfPath = path.join(REPO_ROOT, 'tests', 'fixtures', 'profile', 'call_tree.elf');
  const { proc, wsUrl } = await startServedElf(binPath, elfPath);
  const client = new RA8RpcClient();
  const latencies = [];
  let maxRssMb = 0;
  let foldedBytes = 0;

  try {
    await client.connect(wsUrl);
    await client.continueRun(Core.Cpu0);
    const deadline = Date.now() + durationMs;
    while (Date.now() < deadline) {
      const t0 = performance.now();
      const [metrics, stack, folded] = await Promise.all([
        client.getMetrics(),
        client.getStackReport(Core.Cpu0),
        client.getFolded(Core.Cpu0),
      ]);
      latencies.push(performance.now() - t0);
      if (!Number.isFinite(metrics.hostRssMb) || !Number.isFinite(stack.msp)) {
        throw new Error('Invalid metrics or stack report frame received during soak');
      }
      maxRssMb = Math.max(maxRssMb, metrics.hostRssMb);
      foldedBytes = Math.max(foldedBytes, folded.length);
      await new Promise((r) => setTimeout(r, 40));
    }
    await client.pause(Core.Cpu0);
    latencies.sort((a, b) => a - b);
    console.log(
      JSON.stringify({
        durationMs,
        ops: latencies.length,
        p50Ms: Number(percentile(latencies, 0.5).toFixed(2)),
        p95Ms: Number(percentile(latencies, 0.95).toFixed(2)),
        maxRssMb,
        foldedBytes,
      })
    );
  } finally {
    client.disconnect();
    await stopChild(proc);
  }
}

runSoak().catch((err) => {
  console.error(err);
  process.exit(1);
});
