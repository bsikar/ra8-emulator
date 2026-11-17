import { describe, expect, it } from 'vitest';
import { findBoardPreset } from 'ra8-rpc-client';
import { buildBoardDetailsViewModel } from '../../../src/app/features/workspace/board-details-spec';

describe('board-details-spec', () => {
  it('builds complete silicon, memory map, and fitted parts specifications for EK-RA8P1', () => {
    const preset = findBoardPreset('ra8p1')!;
    const vm = buildBoardDetailsViewModel(preset);
    expect(vm.kitSubtitle).toContain('RTK7EKA8P1S01001BE');
    expect(vm.siliconRows.some((r) => r.label === 'Accelerator' && r.value.includes('Ethos-U55'))).toBe(true);
    expect(vm.memoryRows.some((r) => r.label === '0x8000_0000' && r.value.includes('Octal-SPI'))).toBe(true);
    expect(vm.fittedRows.some((r) => r.value.includes('ER-TFT070-6'))).toBe(true);
  });
});
