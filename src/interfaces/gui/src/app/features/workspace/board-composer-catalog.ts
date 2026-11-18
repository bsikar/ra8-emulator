import type { BoardSiliconPart } from 'ra8-rpc-client';
import type {
  ComposerComponentAttachment,
  ComposerMcuSocket,
} from '../../core/stores/board-composer.types';

export interface SiliconCatalogItem {
  id: string;
  silicon: BoardSiliconPart;
  family: 'RA8' | 'RA4 / RA6';
  title: string;
  partLabel: string;
  packageLabel: string;
  summary: string;
  subline: string;
  hasNpu: boolean;
  coresSummary: Array<{ arch: 'Cortex-M85' | 'Cortex-M33' | 'Ethos-U55'; clockMhz: number; tcmKb: number }>;
  codeNvmKb: number;
  sramKb: number;
}

export interface ComponentCatalogItem {
  id: string;
  name: string;
  category: 'Displays' | 'Sensors' | 'Comms' | 'GPIO';
  summary: string;
  defaultAttachment: Omit<ComposerComponentAttachment, 'id'>;
}

export const BUILTIN_SILICON_CATALOG: readonly SiliconCatalogItem[] = [
  {
    id: 'ra8p1',
    silicon: 'ra8p1',
    family: 'RA8',
    title: 'RA8P1',
    partLabel: 'R7KA8P1KFLCAC',
    packageLabel: '289-BGA · P0-PB (196 pins)',
    summary: 'Cortex-M85 (1 GHz) + Cortex-M33 (250 MHz) + Ethos-U55 (500 MHz)',
    subline: '289-BGA · 1 MB MRAM · 2 MB SRAM',
    hasNpu: true,
    coresSummary: [
      { arch: 'Cortex-M85', clockMhz: 1000, tcmKb: 256 },
      { arch: 'Cortex-M33', clockMhz: 250, tcmKb: 128 },
      { arch: 'Ethos-U55', clockMhz: 500, tcmKb: 0 },
    ],
    codeNvmKb: 1024,
    sramKb: 1664,
  },
  {
    id: 'ra8d2',
    silicon: 'ra8d2',
    family: 'RA8',
    title: 'RA8D2',
    partLabel: 'R7KA8D2KFLCAC',
    packageLabel: '289-BGA · P0-PB (196 pins)',
    summary: 'Cortex-M85 (1 GHz) + Cortex-M33 (250 MHz)',
    subline: '289-BGA · 1 MB MRAM · 2 MB SRAM · GLCDC / MIPI',
    hasNpu: false,
    coresSummary: [
      { arch: 'Cortex-M85', clockMhz: 1000, tcmKb: 256 },
      { arch: 'Cortex-M33', clockMhz: 250, tcmKb: 128 },
    ],
    codeNvmKb: 1024,
    sramKb: 1664,
  },
  {
    id: 'ra8e1',
    silicon: 'ra8e1',
    family: 'RA8',
    title: 'RA8E1',
    partLabel: 'R7FA8E1AFDCFB',
    packageLabel: '144-LQFP · P0-P9 (112 pins)',
    summary: 'Cortex-M85 (360 MHz, Helium MVE)',
    subline: '144-LQFP · 1 MB Code Flash · 544 KB SRAM (32 KB TCM)',
    hasNpu: false,
    coresSummary: [{ arch: 'Cortex-M85', clockMhz: 360, tcmKb: 32 }],
    codeNvmKb: 1024,
    sramKb: 544,
  },
  {
    id: 'ra4t1',
    silicon: 'ra4t1',
    family: 'RA4 / RA6',
    title: 'RA4T1',
    partLabel: 'R7FA4T1BB3CFM',
    packageLabel: '64-LQFP · P0-P5 (48 pins)',
    summary: 'Cortex-M33 (100 MHz, TFU Motor Control)',
    subline: '64-LQFP · 128 KB Code Flash · 40 KB SRAM',
    hasNpu: false,
    coresSummary: [{ arch: 'Cortex-M33', clockMhz: 100, tcmKb: 0 }],
    codeNvmKb: 128,
    sramKb: 40,
  },
];

export const BUILTIN_COMPONENT_CATALOG: readonly ComponentCatalogItem[] = [
  {
    id: 'ov5640',
    name: 'OV5640 5 MP Camera Module',
    category: 'Sensors',
    summary: 'CMOS Image Sensor · MIPI CSI-2 / CEU + I2C SCCB (0x3C)',
    defaultAttachment: {
      name: 'OV5640 5 MP Camera Module',
      category: 'Sensors',
      isCustom: false,
      mountSocket: 'U1',
      endpointLabel: 'CEU + RIIC1 (0x3C)',
      fitSpec: null,
      interfaceKind: 'I2C (Peripheral)',
      pins: [
        { signal: 'SCCB_SCL', pin: 'P512', electrical: 'Open-Drain' },
        { signal: 'SCCB_SDA', pin: 'P511', electrical: 'Open-Drain' },
        { signal: 'CAM_PWDN', pin: 'P401', electrical: 'Output' },
        { signal: 'CAM_RST', pin: 'P400', electrical: 'Output' },
      ],
    },
  },
  {
    id: 'gt911-lcd',
    name: 'GT911 Touch + 7" 1024x600 LCD',
    category: 'Displays',
    summary: 'GLCDC / MIPI-DSI Panel + Capacitive Touch I2C (0x5D)',
    defaultAttachment: {
      name: 'GT911 Touch + Panel',
      category: 'Displays',
      isCustom: false,
      mountSocket: 'U1',
      endpointLabel: 'RIIC1 (0x5D)',
      fitSpec: null,
      interfaceKind: 'I2C (Peripheral)',
      pins: [
        { signal: 'SCL', pin: 'P512', electrical: 'Open-Drain' },
        { signal: 'SDA', pin: 'P511', electrical: 'Open-Drain' },
        { signal: 'INT', pin: 'P004', electrical: 'Falling Edge IRQ' },
        { signal: 'RST', pin: 'P005', electrical: 'Output' },
      ],
    },
  },
  {
    id: 'lsm6dso',
    name: 'LSM6DSO 6-Axis IMU',
    category: 'Sensors',
    summary: '3D Accel + 3D Gyro · I2C (0x6B) or SPI (COPI/CIPO/CS)',
    defaultAttachment: {
      name: 'LSM6DSO IMU',
      category: 'Sensors',
      isCustom: false,
      mountSocket: 'U1',
      endpointLabel: 'SPI0 CS0',
      fitSpec: 'lsm6dso@spi:spi0@ssl0',
      interfaceKind: 'SPI (COPI / CIPO / CS)',
      pins: [
        { signal: 'SCK', pin: 'P102', electrical: 'Push-Pull' },
        { signal: 'COPI', pin: 'P101', electrical: 'Push-Pull' },
        { signal: 'CIPO', pin: 'P100', electrical: 'Input · Pull-up' },
        { signal: 'CS', pin: 'P103', electrical: 'Active-Low CS' },
      ],
    },
  },
  {
    id: 'esp32-c6',
    name: 'ESP32-C6 Wireless Companion',
    category: 'Comms',
    summary: 'esp-hosted Wi-Fi 6 / BLE · UART (SCI) or SPI (COPI/CIPO/CS)',
    defaultAttachment: {
      name: 'ESP32-C6 Companion',
      category: 'Comms',
      isCustom: false,
      mountSocket: 'U1',
      endpointLabel: 'SCI2 UART',
      fitSpec: 'c6@uart:sci2',
      interfaceKind: 'UART (SCI)',
      pins: [
        { signal: 'TXD', pin: 'P302', electrical: 'Push-Pull' },
        { signal: 'RXD', pin: 'P301', electrical: 'Input · Pull-up' },
      ],
    },
  },
  {
    id: 'user-led-sw',
    name: 'User LED / Momentary Switch',
    category: 'GPIO',
    summary: 'Front-Panel RGB565 LED or Switch · GPIO Pin',
    defaultAttachment: {
      name: 'User LED1 + SW1',
      category: 'GPIO',
      isCustom: false,
      mountSocket: 'U1',
      endpointLabel: 'GPIO P600 / P009',
      fitSpec: null,
      interfaceKind: 'GPIO / Timer',
      pins: [
        { signal: 'LED1', pin: 'P600', electrical: 'Output' },
        { signal: 'SW1', pin: 'P009', electrical: 'Input · Pull-up' },
      ],
    },
  },
];

export const DEFAULT_PERIPHERAL_BLOCKS: readonly string[] = [
  'OSPI / xSPI x2',
  'SDRAM 32-bit',
  'SCI / UART x10',
  'SPI x4',
  'RIIC / I3C x3',
  'GLCDC + MIPI-DSI',
  'CEU + MIPI-CSI2',
  'CAN-FD x2',
  'GPT Motor Timers',
  'Ethernet MAC',
];

export function buildSocketFromCatalog(
  item: SiliconCatalogItem,
  designator: string,
  role: 'Primary' | 'Companion',
  interconnect = 'None'
): ComposerMcuSocket {
  return {
    id: `mcu-${designator.toLowerCase()}-${item.id}`,
    designator,
    role,
    silicon: item.silicon,
    partLabel: item.partLabel,
    packageLabel: item.packageLabel,
    interconnect,
    cores: item.coresSummary.map((c, idx) => ({
      id: `${designator.toLowerCase()}-core-${idx}`,
      slotLabel: c.arch === 'Ethos-U55' ? 'NPU 0' : `CORE ${idx}`,
      arch: c.arch,
      clockMhz: c.clockMhz,
      features:
        c.arch === 'Cortex-M85'
          ? 'Helium MVE · TrustZone'
          : c.arch === 'Cortex-M33'
            ? 'FPU · DSP · TrustZone'
            : '256 MACs · 256 GOPS',
      tcmKb: c.tcmKb,
      cacheLabel: c.arch === 'Cortex-M85' ? '32K/32K' : c.arch === 'Cortex-M33' ? '16K' : 'AXI Initiator',
      bootMode: idx === 0 ? 'Reset Primary' : c.arch === 'Ethos-U55' ? 'AXI Initiator' : 'Halted until IPC',
      enabled: true,
    })),
    onChipMemory: [
      { id: 'code-nvm', name: 'Code MRAM', baseHex: '0x02000000', sizeKb: item.codeNvmKb, modeLabel: 'Dual-Bank ECC' },
      { id: 'data-nvm', name: 'Data MRAM', baseHex: '0x27000000', sizeKb: 64, modeLabel: 'Byte-Access ECC' },
      { id: 'sys-sram', name: 'Shared System SRAM', baseHex: '0x22000000', sizeKb: item.sramKb, modeLabel: 'Shared Multi-Core ECC' },
    ],
    peripherals: DEFAULT_PERIPHERAL_BLOCKS.slice(0, 9),
  };
}
