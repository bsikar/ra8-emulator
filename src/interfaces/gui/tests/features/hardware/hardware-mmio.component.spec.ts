import { TestBed } from '@angular/core/testing';
import { HardwareHilStore } from '../../../src/app/core/stores/hardware-hil.store';
import { HardwareMmioComponent, formatMmioHexDump } from '../../../src/app/features/hardware/hardware-mmio.component';

describe('HardwareMmioComponent', () => {
  it('formats 64B MMIO hex dumps and renders selected peripheral dump text', () => {
    expect(formatMmioHexDump(0x4000_0000, new Uint8Array([0xab, 0xcd]))).toBe('0x40000000: ab cd');

    TestBed.configureTestingModule({});
    const hil = TestBed.inject(HardwareHilStore);
    hil.periphBlocks.set(['PORT0', 'SCI8']);
    hil.selectedPeriphBlock.set('SCI8');
    hil.selectedPeriphText.set('SCI8 · SSR = 0x84');

    const fixture = TestBed.createComponent(HardwareMmioComponent);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('PERIPHERAL MMIO');
    expect(el.textContent).toContain('SCI8 · SSR = 0x84');
  });
});
