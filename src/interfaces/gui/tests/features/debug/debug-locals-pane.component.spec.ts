import { TestBed } from '@angular/core/testing';
import { SetVarScope, SetVarStatus } from 'ra8-rpc-client';
import { beforeEach, describe, expect, it } from 'vitest';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { DebugStore } from '../../../src/app/core/stores/debug.store';
import { DebugLocalsPaneComponent } from '../../../src/app/features/debug/debug-locals-pane.component';

describe('DebugLocalsPaneComponent', () => {
  beforeEach(() => {
    TestBed.configureTestingModule({});
  });

  it('edits writable DWARF locals, renders read-only badge for optimized vars, and adds watches', async () => {
    const rpc = TestBed.inject(RpcConnectionStore);
    const debug = TestBed.inject(DebugStore);
    rpc.connectionState.set('connected');

    let updated: { name: string; value: string } | null = null;
    let undone = false;
    debug.setVar = async (name: string, value: string) => {
      updated = { name, value };
      debug.canUndoWrite.set(true);
      return { status: SetVarStatus.Ok, scope: SetVarScope.Local, address: 0x2000_0100, inRegister: 0xff, size: 4, message: 'ok' };
    };
    debug.undoWrite = async () => {
      undone = true;
      debug.canUndoWrite.set(false);
      return true;
    };

    debug.locals.set([
      { name: 'count', typeName: 'uint32_t', size: 4, locationLabel: 'frame-4', valueHex: '0x00000005', valueDec: '5', address: 0x2000_0100 },
      { name: 'opt', typeName: 'int', size: 4, locationLabel: 'optimized out', valueHex: '—', valueDec: '', address: null },
    ]);
    debug.cpu0Registers.set({ pc: 0x0200_0104 });

    const fixture = TestBed.createComponent(DebugLocalsPaneComponent);
    fixture.detectChanges();
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="debug-local-opt"]')?.textContent).toContain('read-only');

    (el.querySelector('[data-testid="debug-local-val-count"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    const editInput = el.querySelector('[data-testid="debug-local-edit-input"]') as HTMLInputElement;
    editInput.value = '42';
    editInput.dispatchEvent(new Event('input'));
    (el.querySelector('[data-testid="debug-local-save-btn"]') as HTMLButtonElement).click();
    await fixture.whenStable();
    fixture.detectChanges();

    expect(updated).toEqual({ name: 'count', value: '42' });
    (el.querySelector('[data-testid="debug-undo-write-btn"]') as HTMLButtonElement).click();
    expect(undone).toBe(true);

    const watchInput = el.querySelector('[data-testid="debug-watch-input"]') as HTMLInputElement;
    watchInput.value = 'pc';
    watchInput.dispatchEvent(new Event('input'));
    (el.querySelector('[data-testid="debug-watch-add-btn"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="debug-watch-row-pc"]')?.textContent).toContain('0x02000104');
  });
});
