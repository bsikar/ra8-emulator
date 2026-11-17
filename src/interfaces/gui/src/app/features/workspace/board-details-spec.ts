import { SHIPPED_PANELS, type BoardPreset } from 'ra8-rpc-client';

export interface BoardSpecRow {
  label: string;
  value: string;
}

export interface BoardDetailsViewModel {
  kitSubtitle: string;
  title: string;
  siliconRows: BoardSpecRow[];
  memoryRows: BoardSpecRow[];
  fittedRows: BoardSpecRow[];
}

function siliconDescriptor(preset: BoardPreset): string {
  switch (preset.silicon) {
    case 'ra8d2':
      return 'U1 · R7KA8D2KFLCAC (289-pin BGA · Armv8.1-M Mainline · TrustZone)';
    case 'ra8p1':
      return 'U1 · R7KA8P1KFLCAC (289-pin BGA · Armv8.1-M Mainline · TrustZone)';
    case 'ra8e1':
      return 'U1 · R7FA8E1AFDCFB (Armv8.1-M Mainline · TrustZone)';
    case 'ra4t1':
      return 'U1 · R7FA4T1BB3CFM (Armv8-M Mainline · Motor Control TFU)';
  }
}

function onChipMemoryRows(preset: BoardPreset): BoardSpecRow[] {
  if (preset.silicon === 'ra8d2' || preset.silicon === 'ra8p1') {
    return [
      { label: '0x0200_0000', value: '1 MB Code MRAM + 64 KB Data MRAM · Non-volatile ECC' },
      { label: '0x2200_0000', value: '2 MB On-Chip SRAM (256 KB M85 TCM + 128 KB M33 TCM)' },
    ];
  }
  if (preset.silicon === 'ra8e1') {
    return [
      { label: '0x0200_0000', value: '1 MB Code Flash + 12 KB Data Flash' },
      { label: '0x2200_0000', value: '544 KB On-Chip SRAM (32 KB TCM)' },
    ];
  }
  return [
    { label: '0x0200_0000', value: '128 KB Code Flash + 4 KB Data Flash' },
    { label: '0x2000_0000', value: '40 KB On-Chip SRAM' },
  ];
}

/** Build full Screen 04a Board Specification rows from a `BoardPreset`. */
export function buildBoardDetailsViewModel(preset: BoardPreset): BoardDetailsViewModel {
  const stem = `${preset.targetId.replace(/-/g, '_')}.board`;
  const kitSubtitle =
    preset.partNumber === 'CUSTOM'
      ? `CUSTOM PROFILE · ${stem}`
      : `${preset.partNumber} · ${stem}`;
  const siliconRows: BoardSpecRow[] = [{ label: 'Primary MCU', value: siliconDescriptor(preset) }];
  preset.cores.forEach((core, idx) => {
    siliconRows.push({
      label: `Core ${idx}`,
      value: `Arm ${core.arch} @ ${core.clockMhz} MHz${core.arch === 'Cortex-M85' ? ' · Helium MVE' : ' · FPU + DSP'}`,
    });
  });
  if (preset.hasNpu) {
    siliconRows.push({
      label: 'Accelerator',
      value: `Arm Ethos-U55 NPU @ ${preset.npuClockMhz} MHz · 256 MACs/cycle (256 GOPS)`,
    });
  }

  const mem = preset.profile.memory;
  const ospiMb = Math.max(1, Math.round(mem.ospi.size / (1024 * 1024)));
  const sdramMb = Math.max(1, Math.round(mem.sdram.size / (1024 * 1024)));
  const memoryRows: BoardSpecRow[] = [
    ...onChipMemoryRows(preset),
    {
      label: '0x8000_0000',
      value: `${ospiMb} MB External Octal-SPI (${mem.ospi.width}-bit @ ${Math.round(mem.ospi.clockHz / 1e6)} MHz · ${mem.ospi.latencyCycles} cyc)`,
    },
    {
      label: '0x9000_0000',
      value: `${sdramMb} MB External SDRAM (${mem.sdram.width}-bit @ ${Math.round(mem.sdram.clockHz / 1e6)} MHz · ${mem.sdram.latencyCycles} cyc)`,
    },
  ];

  const panel = preset.profile.panel ? SHIPPED_PANELS[preset.profile.panel] : null;
  const displayVal = panel
    ? `${panel.name} (${panel.width}x${panel.height} ${panel.format.toUpperCase()})`
    : 'Headless / No on-board panel';
  const ledsVal =
    preset.profile.leds.length > 0
      ? preset.profile.leds.map((l) => `${l.label} (${l.pin})`).join(' · ')
      : 'Custom GPIO pinout';
  const switchesVal =
    preset.profile.switches.length > 0
      ? preset.profile.switches.map((s) => `${s.label} (${s.pin})`).join(' · ')
      : 'No dedicated user switches';

  return {
    kitSubtitle,
    title: preset.name,
    siliconRows,
    memoryRows,
    fittedRows: [
      { label: 'Display Panel', value: displayVal },
      { label: 'User LEDs', value: ledsVal },
      { label: 'User Switches & Bridges', value: `${switchesVal}${preset.profile.companions.length ? ' · ' + preset.profile.companions.join(', ') : ''}` },
    ],
  };
}
