import { TestBed } from '@angular/core/testing';
import { Register } from 'ra8-rpc-client';
import { beforeEach, describe, expect, it } from 'vitest';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { DebugStore } from '../../../src/app/core/stores/debug.store';
import { HardwareHilStore } from '../../../src/app/core/stores/hardware-hil.store';
import { PreferencesStore } from '../../../src/app/core/stores/preferences.store';
import { DebugInspectorPaneComponent } from '../../../src/app/features/debug/debug-inspector-pane.component';

describe('DebugInspectorPaneComponent', () => {
  beforeEach(() => {
    localStorage.clear();
    TestBed.configureTestingModule({});
  });

  it('switches GPR/MVE/Sys registers, dims zeroes, edits register value, and switches Memory/Peripherals tabs', async () => {
    const rpc = TestBed.inject(RpcConnectionStore);
    const debug = TestBed.inject(DebugStore);
    const prefs = TestBed.inject(PreferencesStore);
    const hil = TestBed.inject(HardwareHilStore);

    let written: { reg: Register; val: number } | null = null;
    debug.writeRegister = async (reg: Register, val: number) => {
      written = { reg, val };
      return true;
    };

    rpc.connectionState.set('connected');
    prefs.patch({ dimZeroRegisters: true });
    debug.cpu0PrevRegisters.set({ pc: 0x0200_0100, r0: 0 });
    debug.cpu0Registers.set({ pc: 0x0200_0104, r0: 0, fpscr: 0x10, primask: 1 });
    hil.periphBlocks.set(['SCI8']);
    hil.selectedPeriphText.set('SCR = 0x00000030');

    const fixture = TestBed.createComponent(DebugInspectorPaneComponent);
    fixture.detectChanges();
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('CORE REGISTERS');
    expect(el.querySelector('[data-reg="pc"]')?.classList.contains('is-changed')).toBe(true);
    expect(el.querySelector('[data-reg="r0"]')?.classList.contains('is-dimmed')).toBe(true);

    (el.querySelector('[data-reg="pc"] .reg-val') as HTMLButtonElement).click();
    fixture.detectChanges();
    const regInput = el.querySelector('[data-testid="debug-reg-edit-input"]') as HTMLInputElement;
    regInput.value = '0x02000200';
    regInput.dispatchEvent(new Event('input'));
    regInput.closest('form')!.dispatchEvent(new Event('submit'));
    await fixture.whenStable();
    expect(written).toEqual({ reg: Register.Pc, val: 0x0200_0200 });

    (el.querySelector('[data-testid="debug-reg-group-sys"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(el.querySelector('[data-reg="primask"]')).toBeTruthy();

    (el.querySelector('[data-testid="debug-tab-peripherals"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(el.textContent).toContain('SCR = 0x00000030');
  });
});
