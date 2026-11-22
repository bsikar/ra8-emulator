import { execFileSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Core, RA8RpcClient, Register } from '../client/dist/index.js';

export const GUI_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const REPO_ROOT = path.resolve(GUI_DIR, '..', '..', '..');
export const PWA_DIST_DIR = path.join(GUI_DIR, 'dist', 'ra8-gui', 'browser');

const CODE_BASE = 0x2204_0000;
const DATA_BASE = 0x2204_0100;
const TABLE_BASE = 0x2204_0110;
const GUEST_OPCODES = new Uint16Array([
  0x8008, 0x701a, 0xcc03, 0x6001, 0x42ac, 0xd1fb,
  0x687a, 0x68bb, 0x68fc, 0x6835, 0xbf30, 0x6013,
  0x192d, 0x6035, 0x6838, 0x3001, 0x6038, 0xe7f7,
]);

const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.mjs': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
};

export function resolveEmulatorBinary() {
  const envBin = process.env.RA8_EMULATOR_BIN;
  if (envBin && fs.existsSync(envBin)) return envBin;
  const binName = process.platform === 'win32' ? 'ra8_emulator.exe' : 'ra8_emulator';
  const localBin = path.join(REPO_ROOT, 'zig-out', 'bin', binName);
  if (fs.existsSync(localBin)) return localBin;
  const common = execFileSync('git', ['rev-parse', '--git-common-dir'], { cwd: REPO_ROOT, encoding: 'utf8' }).trim();
  const shared = path.join(path.resolve(REPO_ROOT, common, '..'), 'zig-out', 'bin', binName);
  if (fs.existsSync(shared)) return shared;
  throw new Error(`Missing emulator binary at ${localBin}`);
}

export function stopChild(proc) {
  return new Promise((resolve) => {
    if (proc.killed || proc.exitCode !== null) {
      resolve();
      return;
    }
    const timer = setTimeout(() => resolve(), 2000);
    proc.once('exit', () => {
      clearTimeout(timer);
      resolve();
    });
    proc.kill();
  });
}

export function startServedElf(binPath, relElfPath, extraArgs = []) {
  const elfPath = path.isAbsolute(relElfPath) ? relElfPath : path.join(REPO_ROOT, relElfPath);
  return new Promise((resolve, reject) => {
    const proc = spawn(binPath, ['serve', ...extraArgs, '--listen', 'tcp:127.0.0.1:0', elfPath], {
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
        const port = Number.parseInt(match[1], 10);
        resolve({ proc, port, wsUrl: `ws://127.0.0.1:${port}`, stop: () => stopChild(proc) });
      }
    });
    proc.once('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
    proc.once('exit', (code) => {
      clearTimeout(timer);
      reject(new Error(`Serve exited early (${code}):\n${stderr}`));
    });
  });
}

export function startStaticPwaServer(distDir = PWA_DIST_DIR) {
  if (!fs.existsSync(path.join(distDir, 'index.html'))) {
    throw new Error(`Missing built Angular PWA at ${distDir}. Run "npm run build" in src/interfaces/gui first.`);
  }
  const server = http.createServer((req, res) => {
    const urlPath = (req.url ?? '/').split('?')[0] ?? '/';
    const safeRel = path.normalize(urlPath === '/' ? '/index.html' : urlPath).replace(/^(\.\.[/\\])+/, '');
    let target = path.join(distDir, safeRel);
    if (!fs.existsSync(target) || fs.statSync(target).isDirectory()) {
      target = path.join(distDir, 'index.html');
    }
    const ext = path.extname(target).toLowerCase();
    res.writeHead(200, { 'Content-Type': MIME_TYPES[ext] ?? 'application/octet-stream' });
    fs.createReadStream(target).pipe(res);
  });
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const addr = server.address();
      if (!addr || typeof addr === 'string') {
        reject(new Error('Failed to resolve HTTP server address'));
        return;
      }
      resolve({
        url: `http://127.0.0.1:${addr.port}`,
        close: () => new Promise((done) => server.close(() => done())),
      });
    });
  });
}

export function startTcpRelay(targetPort, oneWayDelayMs = 15) {
  const sockets = new Set();
  const pipeWithDelay = (src, dst) => {
    src.on('data', (chunk) => {
      if (oneWayDelayMs <= 0) {
        if (!dst.destroyed) dst.write(chunk);
        return;
      }
      setTimeout(() => {
        if (!dst.destroyed) dst.write(chunk);
      }, oneWayDelayMs);
    });
    src.on('end', () => { if (!dst.destroyed) dst.end(); });
    src.on('error', () => { if (!dst.destroyed) dst.destroy(); });
  };
  const server = net.createServer((clientSock) => {
    const upstream = net.connect(targetPort, '127.0.0.1');
    sockets.add(clientSock);
    sockets.add(upstream);
    clientSock.once('close', () => sockets.delete(clientSock));
    upstream.once('close', () => sockets.delete(upstream));
    pipeWithDelay(clientSock, upstream);
    pipeWithDelay(upstream, clientSock);
  });
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const addr = server.address();
      if (!addr || typeof addr === 'string') {
        reject(new Error('Failed to bind TCP relay'));
        return;
      }
      resolve({
        wsUrl: `ws://127.0.0.1:${addr.port}`,
        close: () =>
          new Promise((done) => {
            for (const s of sockets) s.destroy();
            server.close(() => done());
          }),
      });
    });
  });
}

function buildAnimDataBlock(framePeriodCycles) {
  const words = [
    1,
    0xe000_ed04,
    0x0200_0000,
    0x0012_1212,
    0x4034_3420, 480,
    0x4034_3410, 272,
    0x4034_3000, 1,
    0x4034_3450, 0x40,
    0x4034_3014, 0xff10_1010,
    0xe000_e014, Math.min(0x00ff_ffff, Math.max(1000, framePeriodCycles - 1)),
    0xe000_e018, 0,
    0xe000_e010, 0x07,
  ];
  const bytes = new Uint8Array(words.length * 4);
  const view = new DataView(bytes.buffer);
  words.forEach((word, i) => view.setUint32(i * 4, word >>> 0, true));
  return bytes;
}

export async function installGlcdcAnimGuest(wsUrl, framePeriodCycles = 10_000_000) {
  const client = new RA8RpcClient();
  await client.connect(wsUrl);
  try {
    const codeBytes = new Uint8Array(GUEST_OPCODES.buffer, GUEST_OPCODES.byteOffset, GUEST_OPCODES.byteLength);
    await client.writeMemory(Core.Cpu0, CODE_BASE, codeBytes);
    await client.writeMemory(Core.Cpu0, DATA_BASE, buildAnimDataBlock(framePeriodCycles));
    const regs = [
      [Register.Primask, 1],
      [Register.R0, 0xa502],
      [Register.R1, 0x4001_e3fa],
      [Register.R2, 0],
      [Register.R3, 0x4001_e110],
      [Register.R4, TABLE_BASE],
      [Register.R5, TABLE_BASE + 8 * 8],
      [Register.R6, 0x4034_3014],
      [Register.R7, DATA_BASE],
      [Register.Pc, CODE_BASE],
    ];
    for (const [reg, value] of regs) {
      await client.writeRegister(Core.Cpu0, reg, value >>> 0);
    }
  } finally {
    client.disconnect();
  }
  await new Promise((r) => setTimeout(r, 60));
}

export async function readGuestState(wsUrl) {
  const client = new RA8RpcClient();
  await client.connect(wsUrl);
  try {
    const mem = await client.readMemory(Core.Cpu0, DATA_BASE, 4);
    const guestFrames = new DataView(mem.buffer, mem.byteOffset, mem.byteLength).getUint32(0, true);
    const virtualNs = await client.now(Core.Cpu0);
    const metrics = await client.getMetrics();
    const regs = {
      pc: await client.readRegister(Core.Cpu0, Register.Pc),
      sp: await client.readRegister(Core.Cpu0, Register.Sp),
      r0: await client.readRegister(Core.Cpu0, Register.R0),
      r1: await client.readRegister(Core.Cpu0, Register.R1),
      r2: await client.readRegister(Core.Cpu0, Register.R2),
      r3: await client.readRegister(Core.Cpu0, Register.R3),
    };
    return { guestFrames, virtualNs, metrics, regs };
  } finally {
    client.disconnect();
  }
}
