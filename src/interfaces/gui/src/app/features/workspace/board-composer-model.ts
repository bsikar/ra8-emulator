import {
  BOARD_MAX_FITS,
  type BoardCoreSpec,
  type BoardLedSpec,
  type BoardPreset,
  type BoardProfile,
  type BoardSwitchSpec,
  OFFICIAL_BOARD_PRESETS,
} from 'ra8-rpc-client';
import type {
  ComposerComponentAttachment,
  ComposerMcuSocket,
  ComposerMemoryRegion,
  StoredCustomBoardPreset,
} from '../../core/stores/board-composer.types';
import {
  BUILTIN_COMPONENT_CATALOG,
  BUILTIN_SILICON_CATALOG,
  buildSocketFromCatalog,
} from './board-composer-catalog';

export interface ComposerDraft {
  id: string;
  isExistingCustom: boolean;
  boardName: string;
  profileFile: string;
  mcus: ComposerMcuSocket[];
  memoryRegions: ComposerMemoryRegion[];
  components: ComposerComponentAttachment[];
}

const MIB = 1024 * 1024;

function nearestPowerOfTwoMib(rawMib: number, maxMib: number): number {
  const clamped = Math.min(maxMib, Math.max(1, Math.round(rawMib || 1)));
  let p = 1;
  while (p * 2 <= clamped) p *= 2;
  return p;
}

function sanitizeStem(raw: string): string {
  const stem = raw
    .trim()
    .replace(/\.board$/i, '')
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, '_')
    .replace(/^_+|_+$/g, '');
  return stem || 'custom_board';
}

function defaultComponentsFromProfile(profile: BoardProfile): ComposerComponentAttachment[] {
  const out: ComposerComponentAttachment[] = [];
  if (profile.panel !== null) {
    const gt = BUILTIN_COMPONENT_CATALOG.find((c) => c.id === 'gt911-lcd')!;
    out.push({ id: 'comp-gt911', ...gt.defaultAttachment, pins: gt.defaultAttachment.pins.map((p) => ({ ...p })) });
  }
  for (const fit of [...profile.sensors, ...profile.companions]) {
    if (fit.startsWith('c6@')) {
      const c6 = BUILTIN_COMPONENT_CATALOG.find((c) => c.id === 'esp32-c6')!;
      out.push({ id: `comp-${fit}`, ...c6.defaultAttachment, fitSpec: fit, pins: c6.defaultAttachment.pins.map((p) => ({ ...p })) });
    } else if (fit.startsWith('lsm6dso@')) {
      const imu = BUILTIN_COMPONENT_CATALOG.find((c) => c.id === 'lsm6dso')!;
      out.push({ id: `comp-${fit}`, ...imu.defaultAttachment, fitSpec: fit, pins: imu.defaultAttachment.pins.map((p) => ({ ...p })) });
    }
  }
  if (profile.leds.length > 0 || profile.switches.length > 0) {
    const gpio = BUILTIN_COMPONENT_CATALOG.find((c) => c.id === 'user-led-sw')!;
    out.push({ id: 'comp-gpio', ...gpio.defaultAttachment, pins: gpio.defaultAttachment.pins.map((p) => ({ ...p })) });
  }
  return out;
}

/** Creates an initial `ComposerDraft` for `+ New Board` or editing an existing preset. */
export function createComposerDraft(source?: BoardPreset | StoredCustomBoardPreset | null): ComposerDraft {
  const custom = source as StoredCustomBoardPreset | null | undefined;
  if (custom?.composer && custom.partNumber === 'CUSTOM') {
    return {
      id: custom.id,
      isExistingCustom: true,
      boardName: custom.name,
      profileFile: custom.composer.profileFile,
      mcus: structuredClone(custom.composer.mcus),
      memoryRegions: structuredClone(custom.composer.memoryRegions),
      components: structuredClone(custom.composer.components),
    };
  }

  const base = source ?? OFFICIAL_BOARD_PRESETS[1]!;
  const isCustom = base.partNumber === 'CUSTOM';
  const cat = BUILTIN_SILICON_CATALOG.find((s) => s.silicon === base.silicon) ?? BUILTIN_SILICON_CATALOG[0]!;
  const u1 = buildSocketFromCatalog(cat, 'U1', 'Primary');
  const ospiMib = Math.max(1, Math.round(base.profile.memory.ospi.size / MIB));
  const sdramMib = Math.max(1, Math.round(base.profile.memory.sdram.size / MIB));
  const stem = sanitizeStem(base.targetId);

  return {
    id: isCustom ? base.id : `custom-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 5)}`,
    isExistingCustom: isCustom,
    boardName: source ? (isCustom ? base.name : `${base.name.split('(')[0]!.trim()} Custom`) : 'Dual-MCU Motor Carrier',
    profileFile: `${source ? stem : 'ra8p1_ra4t1_hil'}.board`,
    mcus: [u1],
    memoryRegions: [
      {
        id: 'mem-ospi0',
        kind: 'Octal-SPI (OSPI)',
        mountSocket: 'U1',
        controllerLabel: 'OSPI0 CS0',
        baseHex: '0x80000000',
        sizeMib: nearestPowerOfTwoMib(ospiMib, 256),
        widthBits: base.profile.memory.ospi.width,
        widthModeLabel: base.profile.memory.ospi.width === 8 ? '8-bit Octal DDR (xSPI)' : `${base.profile.memory.ospi.width}-bit`,
        xipSecurityLabel: 'XIP + DOTF Enabled',
        clockMhz: Math.max(1, Math.round(base.profile.memory.ospi.clockHz / 1_000_000)),
        latencyCycles: base.profile.memory.ospi.latencyCycles,
        burst: base.profile.memory.ospi.burst,
        backing: 'Zero-Initialized',
      },
      {
        id: 'mem-sdram0',
        kind: 'SDRAM',
        mountSocket: 'U1',
        controllerLabel: 'SDRAM CS0',
        baseHex: '0x90000000',
        sizeMib: nearestPowerOfTwoMib(sdramMib, 128),
        widthBits: base.profile.memory.sdram.width,
        widthModeLabel: `${base.profile.memory.sdram.width}-bit`,
        xipSecurityLabel: 'Standard Bus',
        clockMhz: Math.max(1, Math.round(base.profile.memory.sdram.clockHz / 1_000_000)),
        latencyCycles: Math.min(3, Math.max(1, base.profile.memory.sdram.latencyCycles)),
        burst: base.profile.memory.sdram.burst,
        backing: 'Zero-Initialized',
      },
    ],
    components: defaultComponentsFromProfile(base.profile),
  };
}

const DEFAULT_LEDS: readonly BoardLedSpec[] = [
  { pin: 'P600', port: 6, pinIndex: 0, rgb565: 0x001f, label: 'LED1 BLUE' },
  { pin: 'P303', port: 3, pinIndex: 3, rgb565: 0x07e0, label: 'LED2 GREEN' },
];

const DEFAULT_SWITCHES: readonly BoardSwitchSpec[] = [
  { pin: 'P009', port: 0, pinIndex: 9, label: 'SW1' },
];

/** Compiles a `ComposerDraft` into a validated `StoredCustomBoardPreset` ready for `.board` export & storage. */
export function compileDraftToBoardPreset(draft: ComposerDraft): StoredCustomBoardPreset {
  const primaryMcu = draft.mcus[0] ?? buildSocketFromCatalog(BUILTIN_SILICON_CATALOG[0]!, 'U1', 'Primary');
  const cpuEntries = primaryMcu.cores.filter((c): c is typeof c & { arch: 'Cortex-M85' | 'Cortex-M33' } => c.arch !== 'Ethos-U55');
  const cores: BoardCoreSpec[] =
    cpuEntries.length > 0
      ? cpuEntries.slice(0, 2).map((c, idx) => ({
          id: idx === 0 ? 'cpu0' : 'cpu1',
          label: idx === 0 ? 'CPU0 · Primary' : 'CPU1 · Companion',
          arch: c.arch,
          clockMhz: Math.max(1, Math.round(c.clockMhz)),
          enabled: c.enabled,
        }))
      : [{ id: 'cpu0', label: 'CPU0 · Primary', arch: 'Cortex-M85', clockMhz: 1000, enabled: true }];

  const npuCore = primaryMcu.cores.find((c) => c.arch === 'Ethos-U55' && c.enabled);
  const ospiReg = draft.memoryRegions.find((r) => r.kind === 'Octal-SPI (OSPI)');
  const sdramReg = draft.memoryRegions.find((r) => r.kind === 'SDRAM');

  const ospiWidth = ospiReg && [1, 2, 4, 8].includes(ospiReg.widthBits) ? ospiReg.widthBits : 8;
  const sdramWidth = sdramReg && [8, 16, 32].includes(sdramReg.widthBits) ? sdramReg.widthBits : 32;

  const hasDisplay = draft.components.some((c) => c.category === 'Displays' || c.name.toLowerCase().includes('lcd') || c.name.toLowerCase().includes('panel'));
  const hasGpioUi = draft.components.some((c) => c.category === 'GPIO');

  const sensors: string[] = [];
  const companions: string[] = [];
  for (const comp of draft.components) {
    if (!comp.fitSpec || sensors.length + companions.length >= BOARD_MAX_FITS) continue;
    if (comp.category === 'Comms' || comp.fitSpec.startsWith('c6@') || comp.fitSpec.startsWith('modem@')) {
      companions.push(comp.fitSpec);
    } else {
      sensors.push(comp.fitSpec);
    }
  }

  const stem = sanitizeStem(draft.profileFile);
  const profile: BoardProfile = {
    version: 1,
    memory: {
      ospi: {
        size: nearestPowerOfTwoMib(ospiReg?.sizeMib ?? 64, 256) * MIB,
        width: ospiWidth,
        clockHz: Math.min(166_666_667, Math.max(1_000_000, Math.round((ospiReg?.clockMhz ?? 166) * 1_000_000))),
        latencyCycles: Math.min(255, Math.max(0, Math.round(ospiReg?.latencyCycles ?? 8))),
        burst: ospiReg?.burst ?? 'incrementing16',
      },
      sdram: {
        size: nearestPowerOfTwoMib(sdramReg?.sizeMib ?? 64, 128) * MIB,
        width: sdramWidth,
        clockHz: Math.min(133_000_000, Math.max(1_000_000, Math.round((sdramReg?.clockMhz ?? 133) * 1_000_000))),
        latencyCycles: Math.min(3, Math.max(1, Math.round(sdramReg?.latencyCycles ?? 3))),
        burst: sdramReg?.burst ?? 'incrementing16',
      },
      windowCycles: 1_000_000,
    },
    leds: hasGpioUi ? DEFAULT_LEDS.map((l) => ({ ...l })) : [],
    switches: hasGpioUi ? DEFAULT_SWITCHES.map((s) => ({ ...s })) : [],
    panel: hasDisplay ? 'ek_ra8d2' : null,
    sensors,
    companions,
  };

  return {
    id: draft.id,
    partNumber: 'CUSTOM',
    targetId: stem.replace(/_/g, '-'),
    name: draft.boardName.trim() || 'Custom RA8 Board',
    silicon: primaryMcu.silicon,
    hasNpu: Boolean(npuCore),
    npuClockMhz: npuCore ? npuCore.clockMhz : 0,
    cores,
    profile,
    composer: {
      profileFile: `${stem}.board`,
      mcus: structuredClone(draft.mcus),
      memoryRegions: structuredClone(draft.memoryRegions),
      components: structuredClone(draft.components),
    },
  };
}
