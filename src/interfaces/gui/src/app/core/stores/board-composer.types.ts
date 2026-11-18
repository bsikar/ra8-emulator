import type { BoardCoreArch, BoardPreset, BoardSiliconPart } from 'ra8-rpc-client';

export type ComposerInterfaceKind =
  | 'GPIO / Timer'
  | 'I2C (Peripheral)'
  | 'SPI (COPI / CIPO / CS)'
  | 'UART (SCI)'
  | 'ADC / Analog';

export type ComposerSimModelKind = 'Scripted / Register Map' | 'Stimulus CSV' | 'External Socket';

export type ComposerMemoryKind =
  | 'Octal-SPI (OSPI)'
  | 'SDRAM'
  | 'Quad-SPI NOR'
  | 'HyperRAM'
  | 'Custom MMIO';

export type ComposerBackingKind = 'Zero-Initialized' | 'Preload .bin / .hex' | 'Persistent Host File';

export interface ComposerCoreEntry {
  id: string;
  slotLabel: string;
  arch: BoardCoreArch | 'Ethos-U55';
  clockMhz: number;
  features: string;
  tcmKb: number;
  cacheLabel: string;
  bootMode: string;
  enabled: boolean;
}

export interface ComposerOnChipRegion {
  id: string;
  name: string;
  baseHex: string;
  sizeKb: number;
  modeLabel: string;
}

export interface ComposerMcuSocket {
  id: string;
  designator: string;
  role: 'Primary' | 'Companion';
  silicon: BoardSiliconPart;
  partLabel: string;
  packageLabel: string;
  interconnect: string;
  cores: ComposerCoreEntry[];
  onChipMemory: ComposerOnChipRegion[];
  peripherals: string[];
}

export interface ComposerMemoryRegion {
  id: string;
  kind: ComposerMemoryKind;
  mountSocket: string;
  controllerLabel: string;
  baseHex: string;
  sizeMib: number;
  widthBits: number;
  widthModeLabel: string;
  xipSecurityLabel: string;
  clockMhz: number;
  latencyCycles: number;
  burst: 'single' | 'incrementing16';
  backing: ComposerBackingKind;
}

export interface ComposerPinSignal {
  signal: string;
  pin: string;
  electrical: string;
}

export interface ComposerComponentAttachment {
  id: string;
  name: string;
  category: 'Displays' | 'Sensors' | 'Comms' | 'GPIO' | 'Custom';
  isCustom: boolean;
  mountSocket: string;
  endpointLabel: string;
  fitSpec: string | null;
  interfaceKind: ComposerInterfaceKind;
  pins: ComposerPinSignal[];
  simModelKind?: ComposerSimModelKind;
  modelSource?: string;
}

export interface BoardComposerMetadata {
  profileFile: string;
  mcus: ComposerMcuSocket[];
  memoryRegions: ComposerMemoryRegion[];
  components: ComposerComponentAttachment[];
}

export interface StoredCustomBoardPreset extends BoardPreset {
  composer?: BoardComposerMetadata;
}
