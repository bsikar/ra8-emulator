import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { readFile } from 'node:fs/promises';
import { CAP_SESSION_LIFECYCLE, Core, ErrorCode, RA8RpcClient, Topic } from '../dist/index.js';
import { resolveEmulatorBin, resolveFixtureElf } from './helpers/emulator-bin.mjs';

const proc = spawn(resolveEmulatorBin(), ['serve', '--listen', 'tcp:127.0.0.1:0'], { stdio: ['ignore', 'ignore', 'pipe'] });
const exited = once(proc, 'exit');
const client = new RA8RpcClient({ timeoutMs: 15000 });
try {
  const url = await new Promise((resolve, reject) => {
    let output = '';
    const timer = setTimeout(() => reject(new Error(`server startup timed out: ${output}`)), 10000);
    proc.on('error', reject);
    proc.on('exit', () => { clearTimeout(timer); reject(new Error(`server exited: ${output}`)); });
    proc.stderr.on('data', (bytes) => {
      output += bytes;
      const match = /listening on tcp:(127\.0\.0\.1:\d+)/.exec(output);
      if (match) { clearTimeout(timer); resolve(`ws://${match[1]}`); }
    });
  });
  const hello = await client.connect(url);
  assert(hello.caps & CAP_SESSION_LIFECYCLE);
  assert.equal((await client.sessionStatus()).loaded, false);
  await client.subscribe(Core.Cpu0, Topic.Session);
  await assert.rejects(client.step(), (err) => err.code === ErrorCode.AppNoSession);
  await assert.rejects(client.loadElf(Core.Cpu0, new Uint8Array([1, 2, 3])));
  assert.equal((await client.sessionStatus()).loaded, false);
  const image = new Uint8Array(await readFile(resolveFixtureElf('tests/fixtures/gpio/blink.elf')));
  await client.configureSession('ra8d2');
  assert(await client.loadElf(Core.Cpu0, image));
  assert.equal((await client.sessionStatus()).loaded, true);
  await client.step();
  const before = await client.readRegisters(Core.Cpu0);
  await assert.rejects(client.loadElf(Core.Cpu0, new Uint8Array([1, 2, 3])));
  assert.equal((await client.readRegisters(Core.Cpu0)).pc, before.pc);
  await client.closeSession();
  assert.equal((await client.sessionStatus()).loaded, false);
  await assert.rejects(client.step(), (err) => err.code === ErrorCode.AppNoSession);
  const chunked = new Uint8Array(1_100_000);
  chunked.set(image);
  assert(await client.loadElf(Core.Cpu0, chunked));
  await client.step();
  client.disconnect();
  const reconnected = new RA8RpcClient();
  try {
    await reconnected.connect(url);
    assert.equal((await reconnected.sessionStatus()).loaded, true);
    await reconnected.closeSession();
  } finally { reconnected.disconnect(); }
  console.log('PASS idle connect / invalid upload / load / step / failed replacement / close / reload / reconnect');
} finally {
  client.disconnect();
  proc.kill('SIGTERM');
  await exited;
}
