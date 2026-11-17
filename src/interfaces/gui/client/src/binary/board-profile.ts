/**
 * Versioned `.board` profile parser and serializer matching `src/board/profile.zig`.
 */

import {
  BoardLedSpec,
  BoardPanelStem,
  BoardProfile,
  BoardRegionConfig,
  BoardSwitchSpec,
  SHIPPED_PANELS,
  defaultExternalMemory,
} from "./board-presets.js";
import {
  BoardProfileError,
  parsePin,
  parseRegion,
  parseStrictInt,
  validateExternalMemory,
  validateFitSpec,
} from "./board-validate.js";

export * from "./board-presets.js";
export * from "./board-validate.js";

export const BOARD_MAX_FITS = 4;
export const BOARD_MAX_LEDS = 8;
export const BOARD_MAX_SWITCHES = 8;

const TRACKED_LED_PINS = new Set(["P600", "P303", "PA07"]);
const TRACKED_SWITCH_PINS = new Set(["P009", "P008"]);

export interface ParseBoardProfileOptions {
  strictTrackedPads?: boolean;
}

function parseLedLine(entry: string, leds: BoardLedSpec[], strictTracked: boolean): void {
  const parts = entry.split(",");
  if (parts.length !== 3) {
    throw new BoardProfileError("BadLed", `Malformed led directive '${entry}'`);
  }
  const parsedPin = parsePin((parts[0] ?? "").trim());
  const rgb565 = parseStrictInt((parts[1] ?? "").trim(), true);
  const label = (parts[2] ?? "").trim();
  if (!parsedPin || rgb565 === null || rgb565 < 0 || rgb565 > 0xffff || !label) {
    throw new BoardProfileError("BadLed", `Invalid led directive '${entry}'`);
  }
  if (leds.some((item) => item.port === parsedPin.port && item.pinIndex === parsedPin.pinIndex)) {
    throw new BoardProfileError("BadLed", `Duplicate led pin '${parsedPin.pin}'`);
  }
  if (leds.length >= BOARD_MAX_LEDS) {
    throw new BoardProfileError("TooManyLeds", `Exceeds max ${BOARD_MAX_LEDS} LEDs`);
  }
  if (strictTracked && !TRACKED_LED_PINS.has(parsedPin.pin)) {
    throw new BoardProfileError("UntrackedLed", `Untracked LED pad '${parsedPin.pin}'`);
  }
  leds.push({ ...parsedPin, rgb565, label });
}

function parseSwitchLine(entry: string, switches: BoardSwitchSpec[], strictTracked: boolean): void {
  const parts = entry.split(",");
  if (parts.length !== 2) {
    throw new BoardProfileError("BadSwitch", `Malformed switch directive '${entry}'`);
  }
  const parsedPin = parsePin((parts[0] ?? "").trim());
  const label = (parts[1] ?? "").trim();
  if (!parsedPin || !label) {
    throw new BoardProfileError("BadSwitch", `Invalid switch directive '${entry}'`);
  }
  if (switches.some((item) => item.port === parsedPin.port && item.pinIndex === parsedPin.pinIndex)) {
    throw new BoardProfileError("BadSwitch", `Duplicate switch pin '${parsedPin.pin}'`);
  }
  if (switches.length >= BOARD_MAX_SWITCHES) {
    throw new BoardProfileError("TooManySwitches", `Exceeds max ${BOARD_MAX_SWITCHES} switches`);
  }
  if (strictTracked && !TRACKED_SWITCH_PINS.has(parsedPin.pin)) {
    throw new BoardProfileError("UntrackedSwitch", `Untracked switch pad '${parsedPin.pin}'`);
  }
  switches.push({ ...parsedPin, label });
}

/** Parse a version-1 `.board` profile matching `src/board/profile.zig`. */
export function parseBoardProfile(
  text: string,
  options: ParseBoardProfileOptions = {}
): BoardProfile {
  const strictTracked = options.strictTrackedPads ?? true;
  const memory = defaultExternalMemory();
  const leds: BoardLedSpec[] = [];
  const switches: BoardSwitchSpec[] = [];
  const sensors: string[] = [];
  const companions: string[] = [];
  let panel: BoardPanelStem | null = null;
  let hasVersion = false;
  let hasOspi = false;
  let hasSdram = false;
  let hasWindow = false;
  let hasPanel = false;

  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;

    if (line.startsWith("version=")) {
      if (hasVersion || line.slice("version=".length) !== "1") {
        throw new BoardProfileError("BadVersion", `Invalid or duplicate version line '${line}'`);
      }
      hasVersion = true;
    } else if (line.startsWith("ospi=")) {
      if (hasOspi) throw new BoardProfileError("DuplicateMemory", "Duplicate ospi directive");
      memory.ospi = parseRegion(line.slice("ospi=".length));
      hasOspi = true;
    } else if (line.startsWith("sdram=")) {
      if (hasSdram) throw new BoardProfileError("DuplicateMemory", "Duplicate sdram directive");
      memory.sdram = parseRegion(line.slice("sdram=".length));
      hasSdram = true;
    } else if (line.startsWith("memory_window_cycles=")) {
      if (hasWindow) throw new BoardProfileError("DuplicateMemory", "Duplicate memory_window_cycles");
      const val = parseStrictInt(line.slice("memory_window_cycles=".length), false);
      if (val === null) throw new BoardProfileError("BadMemory", `Invalid memory_window_cycles '${line}'`);
      memory.windowCycles = val;
      hasWindow = true;
    } else if (line.startsWith("led=")) {
      parseLedLine(line.slice("led=".length), leds, strictTracked);
    } else if (line.startsWith("switch=")) {
      parseSwitchLine(line.slice("switch=".length), switches, strictTracked);
    } else if (line.startsWith("panel=")) {
      if (hasPanel) throw new BoardProfileError("BadPanel", "Duplicate panel directive");
      hasPanel = true;
      const stem = line.slice("panel=".length);
      if (stem !== "none") {
        if (!(stem in SHIPPED_PANELS)) throw new BoardProfileError("BadPanel", `Unknown panel stem '${stem}'`);
        panel = stem as BoardPanelStem;
      }
    } else if (line.startsWith("sensor=") || line.startsWith("companion=")) {
      if (sensors.length + companions.length >= BOARD_MAX_FITS) {
        throw new BoardProfileError("TooManyFits", `Exceeds max ${BOARD_MAX_FITS} fitted components`);
      }
      const isSensor = line.startsWith("sensor=");
      const spec = line.slice(isSensor ? "sensor=".length : "companion=".length);
      validateFitSpec(spec);
      if (isSensor) sensors.push(spec);
      else companions.push(spec);
    } else {
      throw new BoardProfileError("BadEntry", `Unknown board directive '${line}'`);
    }
  }

  if (!hasVersion) {
    throw new BoardProfileError("BadVersion", "Missing required version=1 directive");
  }
  validateExternalMemory(memory);
  return { version: 1, memory, leds, switches, panel, sensors, companions };
}

function formatRegion(region: BoardRegionConfig): string {
  return [
    `size:${region.size}`,
    `width:${region.width}`,
    `clock_hz:${region.clockHz}`,
    `latency_cycles:${region.latencyCycles}`,
    `burst:${region.burst}`,
  ].join(",");
}

/** Serialize a `BoardProfile` back to canonical `version=1` `.board` text. */
export function serializeBoardProfile(profile: BoardProfile): string {
  validateExternalMemory(profile.memory);
  const lines: string[] = [
    `version=${profile.version}`,
    `ospi=${formatRegion(profile.memory.ospi)}`,
    `sdram=${formatRegion(profile.memory.sdram)}`,
    `memory_window_cycles=${profile.memory.windowCycles}`,
  ];
  for (const led of profile.leds) {
    const hexColor = `0x${(led.rgb565 & 0xffff).toString(16).toUpperCase().padStart(4, "0")}`;
    lines.push(`led=${led.pin},${hexColor},${led.label}`);
  }
  for (const sw of profile.switches) {
    lines.push(`switch=${sw.pin},${sw.label}`);
  }
  lines.push(`panel=${profile.panel ?? "none"}`);
  for (const sensor of profile.sensors) {
    lines.push(`sensor=${sensor}`);
  }
  for (const companion of profile.companions) {
    lines.push(`companion=${companion}`);
  }
  return `${lines.join("\n")}\n`;
}
