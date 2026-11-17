import { execFileSync, spawn, type ChildProcess } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

export interface ServedEmulatorHandle {
  wsUrl: string;
  port: number;
  stop: () => Promise<void>;
}

function resolveRepoRoot(): string {
  let dir = process.cwd();
  for (let i = 0; i < 8; i++) {
    if (fs.existsSync(path.join(dir, 'build.zig'))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return path.resolve(process.cwd(), '..', '..', '..');
}

function resolveEmulatorBinary(repoRoot: string): string {
  const envBin = process.env['RA8_EMULATOR_BIN'];
  if (envBin && fs.existsSync(envBin)) return envBin;
  const binName = process.platform === 'win32' ? 'ra8_emulator.exe' : 'ra8_emulator';
  const worktreeBin = path.join(repoRoot, 'zig-out', 'bin', binName);
  if (fs.existsSync(worktreeBin)) return worktreeBin;
  try {
    const commonDir = execFileSync('git', ['rev-parse', '--git-common-dir'], { cwd: repoRoot, encoding: 'utf8' }).trim();
    const commonRoot = path.resolve(repoRoot, commonDir, '..');
    const mainBin = path.join(commonRoot, 'zig-out', 'bin', binName);
    if (fs.existsSync(mainBin)) return mainBin;
  } catch {
    throw new Error(`Missing emulator binary at ${worktreeBin}. Run "zig build -j1" or set RA8_EMULATOR_BIN.`);
  }
  throw new Error(`Missing emulator binary at ${worktreeBin}. Run "zig build -j1" or set RA8_EMULATOR_BIN.`);
}

export async function startServeFixture(
  relativeElfPath = path.join('tests', 'fixtures', 'gpio', 'blink.elf'),
  extraArgs: readonly string[] = [],
  extraEnv: Record<string, string> = {}
): Promise<ServedEmulatorHandle> {
  const repoRoot = resolveRepoRoot();
  const bin = resolveEmulatorBinary(repoRoot);
  const elf = path.resolve(repoRoot, relativeElfPath);
  if (!fs.existsSync(elf)) {
    throw new Error(`Missing ELF fixture at ${elf}`);
  }

  const proc = spawn(bin, ['serve', ...extraArgs, '--listen', 'tcp:127.0.0.1:0', elf], {
    cwd: repoRoot,
    env: { ...process.env, ...extraEnv },
    stdio: ['pipe', 'pipe', 'pipe'],
  });

  const port = await waitForListeningPort(proc);
  return {
    port,
    wsUrl: `ws://127.0.0.1:${port}`,
    stop: () => stopProcess(proc),
  };
}

function waitForListeningPort(proc: ChildProcess): Promise<number> {
  return new Promise<number>((resolve, reject) => {
    let stderrBuf = '';
    const timer = setTimeout(() => {
      proc.kill();
      reject(new Error(`Timed out waiting for ra8_emulator serve port. stderr:\n${stderrBuf}`));
    }, 10_000);

    proc.stderr?.on('data', (chunk: Buffer | string) => {
      stderrBuf += chunk.toString();
      const match = /serve:\s+listening on tcp:127\.0\.0\.1:(\d+)/.exec(stderrBuf);
      if (match?.[1]) {
        clearTimeout(timer);
        resolve(Number.parseInt(match[1], 10));
      }
    });

    proc.once('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });

    proc.once('exit', (code) => {
      clearTimeout(timer);
      reject(new Error(`ra8_emulator serve exited early (${code}). stderr:\n${stderrBuf}`));
    });
  });
}

function stopProcess(proc: ChildProcess): Promise<void> {
  if (proc.exitCode !== null || proc.killed) return Promise.resolve();
  return new Promise<void>((resolve) => {
    const fallback = setTimeout(() => {
      proc.kill('SIGKILL');
      resolve();
    }, 2000);
    proc.once('exit', () => {
      clearTimeout(fallback);
      resolve();
    });
    proc.kill('SIGTERM');
  });
}
