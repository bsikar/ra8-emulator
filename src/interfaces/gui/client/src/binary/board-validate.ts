/**
 * Validation helpers for `.board` external memory, pin syntax, and component endpoints
 * matching `src/board/external/memory.zig` and `src/components/{request,endpoint}.zig`.
 */

import type {
  BoardBurst,
  BoardExternalMemoryConfig,
  BoardRegionConfig,
} from "./board-presets.js";

const MIB = 1024 * 1024;
const KNOWN_PART_MODELS = new Set([
  "lsm6dso",
  "max17048",
  "eink",
  "modem",
  "c6",
  "button",
  "led",
]);

export type BoardProfileErrorCode =
  | "BadVersion"
  | "BadEntry"
  | "TooManyFits"
  | "BadMemory"
  | "DuplicateMemory"
  | "BadLed"
  | "BadSwitch"
  | "BadPanel"
  | "UntrackedLed"
  | "UntrackedSwitch"
  | "TooManyLeds"
  | "TooManySwitches"
  | "BadRegionConfig"
  | "BadFitSpec";

export class BoardProfileError extends Error {
  constructor(
    public readonly code: BoardProfileErrorCode,
    message: string
  ) {
    super(message);
    this.name = "BoardProfileError";
  }
}

export function parseStrictInt(text: string, allowHex: boolean): number | null {
  if (!text) return null;
  if (allowHex && /^0[xX][0-9a-fA-F]+$/.test(text)) {
    return Number.parseInt(text.slice(2), 16);
  }
  if (/^[0-9]+$/.test(text)) {
    return Number.parseInt(text, 10);
  }
  return null;
}

export function parsePin(text: string): { pin: string; port: number; pinIndex: number } | null {
  if (text.length !== 4 || text[0] !== "P") return null;
  const portChar = text[1] ?? "";
  if (!/^[0-9A-F]$/.test(portChar)) return null;
  const pinHex = text.slice(2, 4);
  if (!/^[0-9a-fA-F]{2}$/.test(pinHex)) return null;
  const port = Number.parseInt(portChar, 16);
  const pinIndex = Number.parseInt(pinHex, 16);
  if (pinIndex > 15) return null;
  return { pin: text, port, pinIndex };
}

export function parseRegion(text: string): BoardRegionConfig {
  const keys = ["size:", "width:", "clock_hz:", "latency_cycles:", "burst:"] as const;
  const fields = text.split(",");
  if (fields.length !== keys.length) {
    throw new BoardProfileError("BadMemory", `Expected 5 region fields, got ${fields.length}`);
  }
  const values: string[] = [];
  for (let i = 0; i < keys.length; i++) {
    const field = fields[i] ?? "";
    const prefix = keys[i]!;
    if (!field.startsWith(prefix) || field.length === prefix.length) {
      throw new BoardProfileError("BadMemory", `Malformed region field '${field}'`);
    }
    values.push(field.slice(prefix.length));
  }
  const size = parseStrictInt(values[0]!, false);
  const width = parseStrictInt(values[1]!, false);
  const clockHz = parseStrictInt(values[2]!, false);
  const latencyCycles = parseStrictInt(values[3]!, false);
  const burstRaw = values[4]!;
  if (size === null || width === null || clockHz === null || latencyCycles === null) {
    throw new BoardProfileError("BadMemory", `Invalid numeric value in region '${text}'`);
  }
  if (burstRaw !== "single" && burstRaw !== "incrementing16") {
    throw new BoardProfileError("BadMemory", `Invalid burst mode '${burstRaw}'`);
  }
  return { size, width, clockHz, latencyCycles, burst: burstRaw as BoardBurst };
}

function validateRegion(kind: "ospi" | "sdram", region: BoardRegionConfig): void {
  const maxSize = kind === "ospi" ? 256 * MIB : 128 * MIB;
  if (region.size < MIB || region.size > maxSize || region.size % MIB !== 0) {
    throw new BoardProfileError("BadRegionConfig", `Invalid ${kind} size ${region.size}`);
  }
  const mibCount = region.size / MIB;
  if ((mibCount & (mibCount - 1)) !== 0) {
    throw new BoardProfileError("BadRegionConfig", `${kind} size must be a power-of-two MiB`);
  }
  const allowedWidths = kind === "ospi" ? [1, 2, 4, 8] : [8, 16, 32];
  if (!allowedWidths.includes(region.width)) {
    throw new BoardProfileError("BadRegionConfig", `Invalid ${kind} width ${region.width}`);
  }
  const maxClock = kind === "ospi" ? 166_670_000 : 133_000_000;
  if (region.clockHz === 0 || region.clockHz > maxClock) {
    throw new BoardProfileError("BadRegionConfig", `Invalid ${kind} clock_hz ${region.clockHz}`);
  }
  if (kind === "ospi" && (region.latencyCycles < 0 || region.latencyCycles > 255)) {
    throw new BoardProfileError("BadRegionConfig", `Invalid ospi latency_cycles ${region.latencyCycles}`);
  }
  if (kind === "sdram" && (region.latencyCycles < 1 || region.latencyCycles > 3)) {
    throw new BoardProfileError("BadRegionConfig", `Invalid sdram latency_cycles ${region.latencyCycles}`);
  }
}

export function validateExternalMemory(memory: BoardExternalMemoryConfig): void {
  validateRegion("ospi", memory.ospi);
  validateRegion("sdram", memory.sdram);
  if (!Number.isInteger(memory.windowCycles) || memory.windowCycles <= 0) {
    throw new BoardProfileError("BadRegionConfig", `Invalid memory_window_cycles ${memory.windowCycles}`);
  }
}

function validateEndpoint(endpoint: string): void {
  const epColon = endpoint.indexOf(":");
  if (epColon <= 0 || epColon === endpoint.length - 1) {
    throw new BoardProfileError("BadFitSpec", `Malformed endpoint '${endpoint}'`);
  }
  const kind = endpoint.slice(0, epColon);
  const where = endpoint.slice(epColon + 1);
  if (kind === "i2c") {
    if (!/^(riic|touch)@(0x[0-9a-fA-F]+|\d+)$/.test(where)) {
      throw new BoardProfileError("BadFitSpec", `Malformed i2c endpoint '${endpoint}'`);
    }
  } else if (kind === "spi") {
    if (!/^spi[01]@ssl[0-3]$/.test(where)) {
      throw new BoardProfileError("BadFitSpec", `Malformed spi endpoint '${endpoint}'`);
    }
  } else if (kind === "uart") {
    if (!/^sci[0-9]$/.test(where)) {
      throw new BoardProfileError("BadFitSpec", `Malformed uart endpoint '${endpoint}'`);
    }
  } else if (kind === "gpio") {
    if (!/^P[0-9A-B](0\d|1[0-5])$/.test(where)) {
      throw new BoardProfileError("BadFitSpec", `Malformed gpio endpoint '${endpoint}'`);
    }
  } else {
    throw new BoardProfileError("BadFitSpec", `Unknown endpoint kind '${kind}'`);
  }
}

export function validateFitSpec(spec: string): void {
  const at = spec.indexOf("@");
  if (at <= 0) {
    throw new BoardProfileError("BadFitSpec", `Malformed part spec '${spec}'`);
  }
  const head = spec.slice(0, at);
  const endpoint = spec.slice(at + 1);
  const colon = head.indexOf(":");
  const model = colon === -1 ? head : head.slice(0, colon);
  if (!KNOWN_PART_MODELS.has(model)) {
    throw new BoardProfileError("BadFitSpec", `Unknown component model '${model}'`);
  }
  if (colon !== -1) {
    if (model !== "eink") {
      throw new BoardProfileError("BadFitSpec", `Size option is only supported on eink, got '${head}'`);
    }
    if (!/^\d+x\d+$/.test(head.slice(colon + 1))) {
      throw new BoardProfileError("BadFitSpec", `Invalid eink geometry '${head.slice(colon + 1)}'`);
    }
  }
  validateEndpoint(endpoint);
}
