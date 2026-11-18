import { TestBed } from '@angular/core/testing';
import { Core } from 'ra8-rpc-client';
import { ExecutionStore } from '../../../src/app/core/stores/execution.store';
import { HardwareHilStore } from '../../../src/app/core/stores/hardware-hil.store';
import { HardwareMmioComponent, formatMmioHexDump } from '../../../src/app/features/hardware/hardware-mmio.component';

describe('HardwareMmioComponent', () => {
  it('filters blocks, selects quick chips, switches cores, and expands peripheral registers', () => {
    expect(formatMmioHexDump(0x4000_0000, new Uint8Array([0xab, 0xcd]))).toBe('0x40000000: ab cd');

    TestBed.configureTestingModule({});
    const hil = TestBed.inject(HardwareHilStore);
    const execution = TestBed.inject(ExecutionStore);
    execution.cpu1Attached.set(true);

    const selectedCalls: Array<{ block: string; core: Core }> = [];
    hil.selectPeriphBlock = async (block: string, core: Core = Core.Cpu0) => {
      selectedCalls.push({ block, core });
      hil.selectedPeriphBlock.set(block);
    };

    hil.periphBlocks.set(['PORT0', 'SCI8', 'RTC']);
    hil.selectedPeriphBlock.set('RTC');
    hil.selectedPeriphText.set(
      'RTC · 0x40200000 · 0x20\n' +
        JSON.stringify({ block: 'RTC', registers: [{ name: 'R64CNT', offset: 0, width: 8 }] })
    );

    const fixture = TestBed.createComponent(HardwareMmioComponent);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('MMIO PERIPHERALS');
    expect(el.textContent).toContain('R64CNT');

    (el.querySelector('.reg-row') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(el.textContent).toContain('8-bit');

    const coreSel = el.querySelector('[data-testid="hardware-mmio-core"]') as HTMLSelectElement;
    coreSel.value = String(Core.Cpu1);
    coreSel.dispatchEvent(new Event('change'));
    expect(selectedCalls[selectedCalls.length - 1]).toEqual({ block: 'RTC', core: Core.Cpu1 });

    (el.querySelector('[data-testid="hardware-mmio-chip-SCI8"]') as HTMLButtonElement).click();
    expect(selectedCalls[selectedCalls.length - 1]).toEqual({ block: 'SCI8', core: Core.Cpu1 });

    const filterInput = el.querySelector('[data-testid="hardware-mmio-filter"]') as HTMLInputElement;
    filterInput.value = 'sci';
    filterInput.dispatchEvent(new Event('input'));
    fixture.detectChanges();
    const opts = Array.from(el.querySelectorAll('[data-testid="hardware-periph-select"] option')).map((o) =>
      o.textContent?.trim()
    );
    expect(opts).toEqual(['SCI8']);
  });
});
