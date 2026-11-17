/**
 * Shipped display panels and official Renesas board presets matching
 * `src/board/panels.zig`, `src/board/ek_ra8d2.board`, and `src/host/toolchain/target.zig`.
 */

export type BoardBurst = "single" | "incrementing16";

export interface BoardRegionConfig {
  size: number;
  width: number;
  clockHz: number;
  latencyCycles: number;
  burst: BoardBurst;
}

export interface BoardExternalMemoryConfig {
  ospi: BoardRegionConfig;
  sdram: BoardRegionConfig;
  windowCycles: number;
}

export interface BoardLedSpec {
  pin: string;
  port: number;
  pinIndex: number;
  rgb565: number;
  label: string;
}

export interface BoardSwitchSpec {
  pin: string;
  port: number;
  pinIndex: number;
  label: string;
}

export type BoardPanelStem =
  | "ek_ra8d2"
  | "sample_480x272"
  | "sample_800x480"
  | "sample_eink";

export interface BoardPanelSpec {
  stem: BoardPanelStem;
  name: string;
  kind: "tft" | "eink";
  width: number;
  height: number;
  format: "rgb565" | "grayscale4";
  ppi: number;
}

export type BoardCoreArch = "Cortex-M85" | "Cortex-M33";

export interface BoardCoreSpec {
  id: "cpu0" | "cpu1";
  label: string;
  arch: BoardCoreArch;
  clockMhz: number;
  enabled: boolean;
}

export type BoardSiliconPart = "ra8d2" | "ra8p1" | "ra8e1" | "ra4t1";

export interface BoardProfile {
  version: 1;
  memory: BoardExternalMemoryConfig;
  leds: BoardLedSpec[];
  switches: BoardSwitchSpec[];
  panel: BoardPanelStem | null;
  sensors: string[];
  companions: string[];
}

export interface BoardPreset {
  id: string;
  partNumber: string;
  targetId: string;
  name: string;
  silicon: BoardSiliconPart;
  hasNpu: boolean;
  npuClockMhz: number;
  cores: readonly BoardCoreSpec[];
  profile: BoardProfile;
}

export const SHIPPED_PANELS: Readonly<Record<BoardPanelStem, BoardPanelSpec>> = {
  ek_ra8d2: {
    stem: "ek_ra8d2",
    name: "ER-TFT070-6",
    kind: "tft",
    width: 1024,
    height: 600,
    format: "rgb565",
    ppi: 169,
  },
  sample_480x272: {
    stem: "sample_480x272",
    name: "Generic 4.3in 480x272",
    kind: "tft",
    width: 480,
    height: 272,
    format: "rgb565",
    ppi: 122,
  },
  sample_800x480: {
    stem: "sample_800x480",
    name: "Generic 7in 800x480",
    kind: "tft",
    width: 800,
    height: 480,
    format: "rgb565",
    ppi: 133,
  },
  sample_eink: {
    stem: "sample_eink",
    name: "E-ink 1072x1448",
    kind: "eink",
    width: 1072,
    height: 1448,
    format: "grayscale4",
    ppi: 300,
  },
};

export function defaultExternalMemory(): BoardExternalMemoryConfig {
  return {
    ospi: {
      size: 256 * 1024 * 1024,
      width: 8,
      clockHz: 166_666_667,
      latencyCycles: 8,
      burst: "incrementing16",
    },
    sdram: {
      size: 128 * 1024 * 1024,
      width: 32,
      clockHz: 133_000_000,
      latencyCycles: 3,
      burst: "incrementing16",
    },
    windowCycles: 1_000_000,
  };
}

const EK_RA8_LEDS: readonly BoardLedSpec[] = [
  { pin: "P600", port: 6, pinIndex: 0, rgb565: 0x001f, label: "LED1 BLUE" },
  { pin: "P303", port: 3, pinIndex: 3, rgb565: 0x07e0, label: "LED2 GREEN" },
  { pin: "PA07", port: 10, pinIndex: 7, rgb565: 0xf800, label: "LED3 RED" },
];

const EK_RA8_SWITCHES: readonly BoardSwitchSpec[] = [
  { pin: "P009", port: 0, pinIndex: 9, label: "SW1" },
  { pin: "P008", port: 0, pinIndex: 8, label: "SW2" },
];

const DUAL_RA8_CORES: readonly BoardCoreSpec[] = [
  { id: "cpu0", label: "CPU0 · Primary", arch: "Cortex-M85", clockMhz: 1000, enabled: true },
  { id: "cpu1", label: "CPU1 · Companion", arch: "Cortex-M33", clockMhz: 250, enabled: true },
];

export const OFFICIAL_BOARD_PRESETS: readonly BoardPreset[] = [
  {
    id: "RTK7EKA8D2S01001BE",
    partNumber: "RTK7EKA8D2S01001BE",
    targetId: "ra8d2",
    name: "EK-RA8D2 (RTK7EKA8D2S01001BE)",
    silicon: "ra8d2",
    hasNpu: false,
    npuClockMhz: 0,
    cores: DUAL_RA8_CORES,
    profile: {
      version: 1,
      memory: defaultExternalMemory(),
      leds: EK_RA8_LEDS.map((led) => ({ ...led })),
      switches: EK_RA8_SWITCHES.map((sw) => ({ ...sw })),
      panel: "ek_ra8d2",
      sensors: [],
      companions: ["c6@uart:sci2"],
    },
  },
  {
    id: "RTK7EKA8P1S01001BE",
    partNumber: "RTK7EKA8P1S01001BE",
    targetId: "ra8p1",
    name: "EK-RA8P1 (RTK7EKA8P1S01001BE)",
    silicon: "ra8p1",
    hasNpu: true,
    npuClockMhz: 500,
    cores: DUAL_RA8_CORES,
    profile: {
      version: 1,
      memory: defaultExternalMemory(),
      leds: EK_RA8_LEDS.map((led) => ({ ...led })),
      switches: EK_RA8_SWITCHES.map((sw) => ({ ...sw })),
      panel: "ek_ra8d2",
      sensors: [],
      companions: ["c6@uart:sci2"],
    },
  },
  {
    id: "RTK7FPA8E1S00001BE",
    partNumber: "RTK7FPA8E1S00001BE",
    targetId: "fpb-ra8e1",
    name: "FPB-RA8E1 (RTK7FPA8E1S00001BE)",
    silicon: "ra8e1",
    hasNpu: false,
    npuClockMhz: 0,
    cores: [{ id: "cpu0", label: "CPU0 · Primary", arch: "Cortex-M85", clockMhz: 360, enabled: true }],
    profile: {
      version: 1,
      memory: {
        ospi: { size: 1024 * 1024, width: 4, clockHz: 83_333_333, latencyCycles: 8, burst: "single" },
        sdram: { size: 1024 * 1024, width: 16, clockHz: 66_500_000, latencyCycles: 2, burst: "single" },
        windowCycles: 1_000_000,
      },
      leds: [],
      switches: [],
      panel: null,
      sensors: [],
      companions: [],
    },
  },
  {
    id: "RTK7FPA4T1S00001BE",
    partNumber: "RTK7FPA4T1S00001BE",
    targetId: "fpb-ra4t1",
    name: "FPB-RA4T1 (RTK7FPA4T1S00001BE)",
    silicon: "ra4t1",
    hasNpu: false,
    npuClockMhz: 0,
    cores: [{ id: "cpu0", label: "CPU0 · Primary", arch: "Cortex-M33", clockMhz: 100, enabled: true }],
    profile: {
      version: 1,
      memory: {
        ospi: { size: 1024 * 1024, width: 1, clockHz: 41_666_667, latencyCycles: 8, burst: "single" },
        sdram: { size: 1024 * 1024, width: 8, clockHz: 66_500_000, latencyCycles: 2, burst: "single" },
        windowCycles: 1_000_000,
      },
      leds: [],
      switches: [],
      panel: null,
      sensors: [],
      companions: [],
    },
  },
];

/** Look up an official Renesas board preset by part number or target ID. */
export function findBoardPreset(idOrPartNumber: string): BoardPreset | undefined {
  const needle = idOrPartNumber.trim().toLowerCase();
  return OFFICIAL_BOARD_PRESETS.find(
    (preset) =>
      preset.partNumber.toLowerCase() === needle ||
      preset.targetId.toLowerCase() === needle
  );
}
