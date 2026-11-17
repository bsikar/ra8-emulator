import { Core, RA8RpcClient } from "../dist/index.js";
import { resolveEmulatorBin, resolveFixtureElf, startEmulatorServe } from "./helpers/emulator-bin.mjs";

async function verifyCoreInspection(client) {
  const metrics = await client.getMetrics();
  console.log(`✓ getMetrics(): hostCpu=${metrics.hostCpuPercent}%, hostRss=${metrics.hostRssMb}MB, hostThreads=${metrics.hostThreads}, cpu0Load=${metrics.cpu0LoadPercent}%, cpu0RamUsed=${metrics.cpu0RamUsedBytes}`);
  if (typeof metrics.hostCpuPercent !== "number" || typeof metrics.cpu0LoadPercent !== "number") {
    throw new Error("Invalid metrics response structure");
  }

  const regs1 = await client.readRegisters(Core.Cpu0);
  console.log(`✓ readRegisters() initial PC=0x${regs1.pc?.toString(16)}, SP=0x${regs1.sp?.toString(16)}`);

  const stepAck = await client.step(Core.Cpu0);
  console.log(`✓ step() acknowledged: ${stepAck}`);

  const regs2 = await client.readRegisters(Core.Cpu0);
  console.log(`✓ readRegisters() after step: PC=0x${regs2.pc?.toString(16)}`);

  const mem = await client.readMemory(Core.Cpu0, 0x02000000, 16);
  console.log(`✓ readMemory(0x02000000, 16): ${Array.from(mem).map((b) => b.toString(16).padStart(2, "0")).join(" ")}`);
  if (mem.length !== 16) {
    throw new Error(`Expected 16 bytes memory, got ${mem.length}`);
  }
}

async function verifyDisasmAndBoard(client) {
  const disasm = await client.disassemble(Core.Cpu0, { usePc: true, count: 8 });
  console.log(`✓ disassemble(CPU0, usePc=true, count=8): pc=0x${disasm.pc.toString(16)}, rows=${disasm.rows.length}, first="${disasm.rows[0]?.text}"`);
  if (disasm.rows.length === 0 || !disasm.rows[0]?.decoded || !disasm.rows[0]?.text) {
    throw new Error("Expected decoded disassembly rows from Zig backend");
  }

  const boardParts = await client.getBoardParts();
  console.log(`✓ getBoardParts(): panel="${boardParts.panel}" (${boardParts.panelWidth}x${boardParts.panelHeight}), LEDs=[${boardParts.ledNames.join(", ")}], switches=[${boardParts.switchNames.join(", ")}]`);
  if (boardParts.switchNames.length === 0) {
    throw new Error("Expected dynamic switchNames from boardParts");
  }

  const stack = await client.getStackReport(Core.Cpu0);
  console.log(`✓ getStackReport(CPU0): msp=0x${stack.msp.toString(16)}, lowMsp=0x${stack.lowMsp.toString(16)}`);

  const periphBlocks = await client.getPeriph(Core.Cpu0, "");
  console.log(`✓ getPeriph(CPU0, ""): ${periphBlocks.trim().split("\n").length} blocks reported`);

  const vns = await client.now(Core.Cpu0);
  console.log(`✓ now(CPU0): ${vns} ns`);

  const bpAddr = disasm.rows[0].address;
  const bpId = await client.setBreakpointId(Core.Cpu0, bpAddr);
  const cleared = await client.clearBreakpointById(Core.Cpu0, bpId);
  console.log(`✓ setBreakpointId(0x${bpAddr.toString(16)}) => id=${bpId}, clearBreakpointById(${bpId}) => ${cleared}`);
  if (!cleared) {
    throw new Error("Expected clearBreakpointById to succeed");
  }
}

async function runLiveTest() {
  console.log("=== EMPIRICAL TEST: Live RA8 Emulator WebSocket RPC ===");

  const port = 24892;
  const emulatorPath = resolveEmulatorBin();
  const fixtureElf = resolveFixtureElf("tests/fixtures/gpio/blink.elf");
  console.log(`Starting emulator: ${emulatorPath} serve --listen tcp:127.0.0.1:${port} ${fixtureElf}`);

  const server = await startEmulatorServe(port, fixtureElf, {
    onStdout: (line) => console.log(`[EMU stdout] ${line}`),
    onStderr: (line) => console.log(`[EMU stderr] ${line}`),
  });

  console.log("Emulator server is listening. Connecting RA8RpcClient via WebSocket...");
  const client = new RA8RpcClient({ timeoutMs: 5000 });

  try {
    const hello = await client.connect(`ws://127.0.0.1:${port}`);
    console.log(`✓ WebSocket connected and handshook: magic=0x${hello.magic.toString(16)}, version=${hello.version}, caps=0x${hello.caps.toString(16)}`);
    await verifyCoreInspection(client);
    await verifyDisasmAndBoard(client);
    client.disconnect();
    console.log("✓ Client disconnected cleanly");
  } finally {
    server.stop();
    console.log("Emulator process terminated.");
  }
}

runLiveTest().then(
  () => {
    console.log("\n>>> LIVE EMULATOR WEBSOCKET RPC TEST PASSED! <<<\n");
    process.exit(0);
  },
  (err) => {
    console.error("\n>>> LIVE EMULATOR WEBSOCKET RPC TEST FAILED:", err);
    process.exit(1);
  }
);
