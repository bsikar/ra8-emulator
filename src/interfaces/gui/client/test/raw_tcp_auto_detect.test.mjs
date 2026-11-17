import net from "node:net";
import {
  Kind,
  PROTOCOL_MAGIC,
  PROTOCOL_VERSION,
  decodeHello,
  encodeFrame,
  encodeHello,
  splitFrames,
} from "../dist/index.js";
import { resolveFixtureElf, startEmulatorServe } from "./helpers/emulator-bin.mjs";

function connectRawTcp(port) {
  return new Promise((resolveSocket, rejectSocket) => {
    const socket = new net.Socket();
    socket.on("error", rejectSocket);
    socket.connect(port, "127.0.0.1", () => resolveSocket(socket));
  });
}

function readNextRawFrame(socket, timeoutMs = 3000) {
  const receivedChunks = [];
  return new Promise((resolveFrame, rejectFrame) => {
    const timer = setTimeout(() => rejectFrame(new Error("Timeout waiting for raw TCP response")), timeoutMs);
    socket.on("data", (chunk) => {
      receivedChunks.push(chunk);
      const { frames } = splitFrames(new Uint8Array(Buffer.concat(receivedChunks)));
      if (frames.length > 0) {
        clearTimeout(timer);
        resolveFrame(frames[0]);
      }
    });
    socket.on("error", (err) => {
      clearTimeout(timer);
      rejectFrame(err);
    });
  });
}

async function testRawTcpNonInterference() {
  console.log("=== EMPIRICAL TEST: Raw TCP RPC Non-Interference Auto-Detection ===");

  const port = 24893;
  const fixtureElf = resolveFixtureElf("tests/fixtures/gpio/blink.elf");
  const server = await startEmulatorServe(port, fixtureElf);

  try {
    const socket = await connectRawTcp(port);
    console.log("Connected raw TCP socket. Sending raw Kind.Hello frame...");
    socket.write(encodeFrame(Kind.Hello, encodeHello(0x0000ffff)));

    const respFrame = await readNextRawFrame(socket);
    console.log(`Received raw frame: kind=${respFrame.kind}`);
    if (respFrame.kind !== Kind.Hello) {
      throw new Error(`Expected Kind.Hello (1), got ${respFrame.kind}`);
    }

    const decoded = decodeHello(respFrame.payload);
    console.log(`✓ Decoded raw server Hello: magic=0x${decoded.magic.toString(16)}, version=${decoded.version}, caps=0x${decoded.caps.toString(16)}`);

    if (decoded.magic !== PROTOCOL_MAGIC || decoded.version !== PROTOCOL_VERSION) {
      throw new Error("Invalid magic or version in raw response");
    }

    socket.end();
    console.log("✓ Raw TCP non-interference verified successfully!");
  } finally {
    server.stop();
  }
}

testRawTcpNonInterference().then(
  () => {
    console.log("\n>>> RAW TCP NON-INTERFERENCE TEST PASSED! <<<\n");
    process.exit(0);
  },
  (err) => {
    console.error("\n>>> RAW TCP NON-INTERFERENCE TEST FAILED:", err);
    process.exit(1);
  }
);
