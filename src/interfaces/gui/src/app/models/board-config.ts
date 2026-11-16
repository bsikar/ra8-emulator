export type SiliconTopology = 'single' | 'dual' | 'multi';

export type CoreArch = 'Cortex-M85' | 'Cortex-M33';

export interface CoreSlotSpec {
  id: string;
  label: string;
  arch: CoreArch;
  clockMhz: number;
  enabled: boolean;
  role: string;
}

export interface BoardProfileConfig {
  id: string;
  name: string;
  fileName: string;
  version: number;
  topology: SiliconTopology;
  npuEnabled: boolean;
  npuClockMhz: number;
  ospiMiB: number;
  sdramMiB: number;
  memoryWindowCycles: number;
  panel: string;
  sensor: string;
  ledsRaw: string;
  switchesRaw: string;
  companionEnabled: boolean;
  cores: CoreSlotSpec[];
}

function makeCoresForTopology(mode: SiliconTopology, existing?: readonly CoreSlotSpec[]): CoreSlotSpec[] {
  if (mode === 'single') {
    return [
      { id: 'CPU0', label: 'CPU0 · Primary', arch: 'Cortex-M85', clockMhz: 1000, enabled: true, role: 'Primary Compute' },
    ];
  }
  if (mode === 'dual') {
    return [
      { id: 'CPU0', label: 'CPU0 · Primary', arch: 'Cortex-M85', clockMhz: 1000, enabled: true, role: 'Primary Compute' },
      { id: 'CPU1', label: 'CPU1 · Companion', arch: 'Cortex-M33', clockMhz: 250, enabled: true, role: 'I/O & Low-Power Companion' },
    ];
  }
  if (existing && existing.length >= 3) {
    return existing.map((c) => ({ ...c }));
  }
  return [
    { id: 'CPU0', label: 'CPU0 · Primary', arch: 'Cortex-M85', clockMhz: 1000, enabled: true, role: 'Vision & Control' },
    { id: 'CPU1', label: 'CPU1 · Companion', arch: 'Cortex-M33', clockMhz: 250, enabled: true, role: 'Sensor & Bus I/O' },
    { id: 'CPU2', label: 'CPU2 · Worker', arch: 'Cortex-M85', clockMhz: 480, enabled: true, role: 'DSP / Telemetry' },
  ];
}

export const BOARD_PRESETS: readonly BoardProfileConfig[] = [
  {
    id: 'ek_ra8m1_single',
    name: 'Single-Core RA8M1',
    fileName: 'ek_ra8m1.board',
    version: 1,
    topology: 'single',
    npuEnabled: false,
    npuClockMhz: 0,
    ospiMiB: 16,
    sdramMiB: 0,
    memoryWindowCycles: 64,
    panel: 'none',
    sensor: 'none',
    ledsRaw: 'red@p000,green@p001',
    switchesRaw: 'user@p003',
    companionEnabled: false,
    cores: makeCoresForTopology('single'),
  },
  {
    id: 'ek_ra8d2_dual',
    name: 'Dual M85+M33 + NPU',
    fileName: 'ek_ra8d2.board',
    version: 1,
    topology: 'dual',
    npuEnabled: true,
    npuClockMhz: 500,
    ospiMiB: 32,
    sdramMiB: 64,
    memoryWindowCycles: 128,
    panel: 'ER-TFT070-6',
    sensor: 'imx477@cam0',
    ledsRaw: 'red@p000,green@p001,blue@p002',
    switchesRaw: 'user@p003',
    companionEnabled: true,
    cores: makeCoresForTopology('dual'),
  },
  {
    id: 'ra8_cluster_multi',
    name: 'Multi-Core Cluster + NPU',
    fileName: 'ra8_cluster.board',
    version: 1,
    topology: 'multi',
    npuEnabled: true,
    npuClockMhz: 500,
    ospiMiB: 64,
    sdramMiB: 128,
    memoryWindowCycles: 128,
    panel: 'ER-TFT070-6',
    sensor: 'imx477@cam0',
    ledsRaw: 'red@p000,green@p001,blue@p002',
    switchesRaw: 'user@p003,mode@p004',
    companionEnabled: true,
    cores: [
      { id: 'CPU0', label: 'CPU0 · Primary', arch: 'Cortex-M85', clockMhz: 1000, enabled: true, role: 'Vision & Control' },
      { id: 'CPU1', label: 'CPU1 · Companion', arch: 'Cortex-M33', clockMhz: 250, enabled: true, role: 'Sensor & Bus I/O' },
      { id: 'CPU2', label: 'CPU2 · Worker', arch: 'Cortex-M85', clockMhz: 480, enabled: true, role: 'DSP / Telemetry' },
      { id: 'CPU3', label: 'CPU3 · Safety', arch: 'Cortex-M33', clockMhz: 250, enabled: true, role: 'Watchdog & HIL' },
    ],
  },
];

function parseSizeMiB(raw: string, fallback: number): number {
  const m = raw.trim().match(/^(\d+)\s*([kmgKMG])?[bB]?$/);
  if (!m) return fallback;
  const val = Number.parseInt(m[1], 10);
  const unit = (m[2] ?? 'M').toUpperCase();
  if (unit === 'G') return val * 1024;
  if (unit === 'K') return Math.max(1, Math.round(val / 1024));
  return val;
}

export function parseBoardConfig(fileName: string, text: string): BoardProfileConfig {
  const kv = new Map<string, string>();
  for (const rawLine of text.split(/\r?\n/)) {
    const trimmed = rawLine.trim();
    if (!trimmed) continue;
    const uncommented = trimmed.startsWith('# ra8-meta:') ? trimmed.slice(11).trim() : trimmed;
    if (uncommented.startsWith('#')) continue;
    const eq = uncommented.indexOf('=');
    if (eq <= 0) continue;
    kv.set(uncommented.slice(0, eq).trim().toLowerCase(), uncommented.slice(eq + 1).trim());
  }

  const companionVal = (kv.get('companion') ?? 'enabled').toLowerCase();
  const companionEnabled = companionVal !== 'disabled' && companionVal !== 'false' && companionVal !== '0';

  const rawTopology = (kv.get('topology') ?? '').toLowerCase();
  const topology: SiliconTopology =
    rawTopology === 'multi'
      ? 'multi'
      : rawTopology === 'single'
        ? 'single'
        : rawTopology === 'dual'
          ? 'dual'
          : companionEnabled
            ? 'dual'
            : 'single';

  const ospiMiB = parseSizeMiB(kv.get('ospi') ?? '32M', 32);
  const sdramMiB = parseSizeMiB(kv.get('sdram') ?? '64M', 64);
  const memoryWindowCycles = Number.parseInt(kv.get('memory_window_cycles') ?? '128', 10) || 128;
  const version = Number.parseInt(kv.get('version') ?? '1', 10) || 1;

  const npuRaw = (kv.get('npu') ?? '').toLowerCase();
  const npuEnabled = npuRaw ? npuRaw !== 'disabled' && npuRaw !== 'off' && npuRaw !== '0' : companionEnabled || ospiMiB >= 32;

  const explicitCores: CoreSlotSpec[] = [];
  const coresCsv = kv.get('cores');
  if (coresCsv) {
    const parts = coresCsv.split(',').map((s) => s.trim()).filter(Boolean);
    parts.forEach((part, idx) => {
      const [archPart, mhzPart] = part.split('@');
      const arch: CoreArch = archPart?.toLowerCase().includes('m33') ? 'Cortex-M33' : 'Cortex-M85';
      const defaultMhz = arch === 'Cortex-M85' ? 1000 : 250;
      const clockMhz = Number.parseInt(mhzPart ?? String(defaultMhz), 10) || defaultMhz;
      explicitCores.push({
        id: `CPU${idx}`,
        label: `CPU${idx} · ${idx === 0 ? 'Primary' : 'Worker'}`,
        arch,
        clockMhz,
        enabled: true,
        role: idx === 0 ? 'Primary Compute' : 'Peripheral / Worker',
      });
    });
  }

  const cores = explicitCores.length > 0 ? explicitCores : makeCoresForTopology(topology);
  const resolvedTopology: SiliconTopology = cores.length >= 3 ? 'multi' : cores.length === 2 ? 'dual' : 'single';

  return {
    id: fileName.replace(/[^a-zA-Z0-9_-]/g, '_'),
    name: kv.get('name') ?? fileName.replace(/\.board$/i, ''),
    fileName,
    version,
    topology: resolvedTopology,
    npuEnabled,
    npuClockMhz: npuEnabled ? 500 : 0,
    ospiMiB,
    sdramMiB,
    memoryWindowCycles,
    panel: kv.get('panel') ?? 'ER-TFT070-6',
    sensor: kv.get('sensor') ?? 'imx477@cam0',
    ledsRaw: kv.get('led') ?? 'red@p000,green@p001,blue@p002',
    switchesRaw: kv.get('switch') ?? 'user@p003',
    companionEnabled: resolvedTopology !== 'single',
    cores,
  };
}

export function serializeBoardConfig(cfg: BoardProfileConfig): string {
  const coreSpec = cfg.cores.map((c) => `${c.arch}@${c.clockMhz}`).join(',');
  return [
    `version=${cfg.version}`,
    `ospi=${cfg.ospiMiB}M`,
    `sdram=${cfg.sdramMiB}M`,
    `memory_window_cycles=${cfg.memoryWindowCycles}`,
    `led=${cfg.ledsRaw}`,
    `switch=${cfg.switchesRaw}`,
    `panel=${cfg.panel}`,
    `sensor=${cfg.sensor}`,
    `companion=${cfg.companionEnabled || cfg.cores.length > 1 ? 'enabled' : 'disabled'}`,
    `# ra8-meta: topology=${cfg.topology}`,
    `# ra8-meta: npu=${cfg.npuEnabled ? 'enabled' : 'disabled'}`,
    `# ra8-meta: cores=${coreSpec}`,
  ].join('\n');
}

export function setTopologyMode(cfg: BoardProfileConfig, mode: SiliconTopology): BoardProfileConfig {
  const cores = makeCoresForTopology(mode, mode === 'multi' ? cfg.cores : undefined);
  return {
    ...cfg,
    topology: mode,
    companionEnabled: mode !== 'single',
    cores,
  };
}

export function addCoreSlot(cfg: BoardProfileConfig, arch: CoreArch = 'Cortex-M33'): BoardProfileConfig {
  const idx = cfg.cores.length;
  const nextCore: CoreSlotSpec = {
    id: `CPU${idx}`,
    label: `CPU${idx} · ${arch === 'Cortex-M85' ? 'Compute' : 'I/O'}`,
    arch,
    clockMhz: arch === 'Cortex-M85' ? 1000 : 250,
    enabled: true,
    role: arch === 'Cortex-M85' ? 'Parallel Compute' : 'Peripheral / Telemetry',
  };
  const cores = [...cfg.cores, nextCore];
  const topology: SiliconTopology = cores.length >= 3 ? 'multi' : cores.length === 2 ? 'dual' : 'single';
  return {
    ...cfg,
    cores,
    topology,
    companionEnabled: cores.length > 1,
  };
}

export function removeCoreSlot(cfg: BoardProfileConfig, index: number): BoardProfileConfig {
  if (cfg.cores.length <= 1 || index < 0 || index >= cfg.cores.length) {
    return cfg;
  }
  const filtered = cfg.cores.filter((_, i) => i !== index).map((c, i) => ({
    ...c,
    id: `CPU${i}`,
  }));
  const topology: SiliconTopology = filtered.length >= 3 ? 'multi' : filtered.length === 2 ? 'dual' : 'single';
  return {
    ...cfg,
    cores: filtered,
    topology,
    companionEnabled: filtered.length > 1,
  };
}

export function toggleNpu(cfg: BoardProfileConfig, enabled?: boolean): BoardProfileConfig {
  const npuEnabled = enabled ?? !cfg.npuEnabled;
  return {
    ...cfg,
    npuEnabled,
    npuClockMhz: npuEnabled ? 500 : 0,
  };
}
