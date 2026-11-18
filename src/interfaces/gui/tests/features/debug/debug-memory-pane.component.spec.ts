import { TestBed } from '@angular/core/testing';
import { Core } from 'ra8-rpc-client';
import { beforeEach, describe, expect, it } from 'vitest';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { DebugStore } from '../../../src/app/core/stores/debug.store';
import { DebugMemoryPaneComponent } from '../../../src/app/features/debug/debug-memory-pane.component';

describe('DebugMemoryPaneComponent', () => {
  beforeEach(() => {
    TestBed.configureTestingModule({});
  });

  it('jumps on active core, highlights changed bytes, and pokes bytes via writeMemoryBytes', async () => {
    const rpc = TestBed.inject(RpcConnectionStore);
    const debug = TestBed.inject(DebugStore);
    rpc.connectionState.set('connected');
    debug.activeCore.set(Core.Cpu1);

    const calls: Array<{ core: Core; addr: number; byte?: number }> = [];
    debug.readMemoryPage = async (addr = 0x2200_0000, _len = 256, core = debug.activeCore()) => {
      calls.push({ core, addr });
      const data = new Uint8Array([0x11, 0x22, 0x33, 0x44]);
      debug.memoryAddress.set(addr);
      debug.memoryPrevBytes.set(new Uint8Array([0x11, 0x00, 0x33, 0x44]));
      debug.memoryBytes.set(data);
      return data;
    };
    debug.writeMemoryBytes = async (addr: number, bytes: Uint8Array, core = debug.activeCore()) => {
      calls.push({ core, addr, byte: bytes[0] });
      return true;
    };

    const fixture = TestBed.createComponent(DebugMemoryPaneComponent);
    fixture.detectChanges();
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    (el.querySelector('[data-testid="debug-mem-sram"]') as HTMLButtonElement).click();
    await fixture.whenStable();
    fixture.detectChanges();

    expect(calls[0]).toEqual({ core: Core.Cpu1, addr: 0x2200_0000 });
    const changedCell = el.querySelector('[data-mem-offset="1"]') as HTMLButtonElement;
    expect(changedCell.classList.contains('is-changed')).toBe(true);

    changedCell.click();
    fixture.detectChanges();
    const pokeInput = el.querySelector('[data-testid="debug-mem-poke-input"]') as HTMLInputElement;
    pokeInput.value = 'aa';
    pokeInput.dispatchEvent(new Event('input'));
    pokeInput.closest('form')!.dispatchEvent(new Event('submit'));
    await fixture.whenStable();

    expect(calls[1]).toEqual({ core: Core.Cpu1, addr: 0x2200_0001, byte: 0xaa });
  });
});
