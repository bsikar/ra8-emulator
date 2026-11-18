import { TestBed } from '@angular/core/testing';
import { Core, StopReason } from 'ra8-rpc-client';
import { beforeEach, describe, expect, it } from 'vitest';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { DebugStore } from '../../../src/app/core/stores/debug.store';
import { ExecutionStore } from '../../../src/app/core/stores/execution.store';
import { VimStore } from '../../../src/app/core/vim/vim.store';
import { DebugCodePaneComponent } from '../../../src/app/features/debug/debug-code-pane.component';

describe('DebugCodePaneComponent', () => {
  beforeEach(() => {
    localStorage.clear();
    TestBed.configureTestingModule({});
  });

  it('switches Source/Disasm/Mixed/Decomp modes, toggles gutter breakpoint, and moves Vim cursor', async () => {
    const rpc = TestBed.inject(RpcConnectionStore);
    const debug = TestBed.inject(DebugStore);
    const execution = TestBed.inject(ExecutionStore);
    const vim = TestBed.inject(VimStore);

    let toggledAddr = -1;
    let skipped = false;
    debug.toggleBreakpoint = async (addr: number) => {
      toggledAddr = addr;
      return true;
    };
    execution.skipBkpt = async () => {
      skipped = true;
    };

    rpc.connectionState.set('connected');
    execution.lastStop.set({ core: Core.Cpu0, reason: StopReason.Breakpoint, address: 0x0200_0100, detail: 0 });
    debug.cpu0Registers.set({ pc: 0x0200_0100 });
    debug.cpu0Disasm.set([
      { address: 0x0200_0100, size: 2, decoded: true, raw: new Uint8Array([0x00, 0xbe]), text: 'bkpt #0', symbol: 'main' },
      { address: 0x0200_0102, size: 2, decoded: true, raw: new Uint8Array([0x01, 0x20]), text: 'movs r0, #1', symbol: 'main' },
    ]);
    debug.sourceLine.set({ found: true, pc: 0x0200_0100, line: 2, path: 'main.c' });
    debug.sourceFileLines.set(['int main(void) {', '  return 1;', '}']);

    const fixture = TestBed.createComponent(DebugCodePaneComponent);
    fixture.detectChanges();
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="debug-disasm"]')?.textContent).toContain('bkpt #0');
    let skippedCore = Core.Cpu0;
    execution.skipBkpt = async (core = Core.Cpu0) => {
      skipped = true;
      skippedCore = core;
    };
    debug.activeCore.set(Core.Cpu1);
    debug.cpu1Registers.set({ pc: 0x0200_0100 });
    debug.cpu1Disasm.set([
      { address: 0x0200_0100, size: 2, decoded: true, raw: new Uint8Array([0x00, 0xbe]), text: 'bkpt #0', symbol: 'main' },
    ]);
    execution.lastStop.set({ core: Core.Cpu1, reason: StopReason.Breakpoint, address: 0x0200_0100, detail: 0 });
    fixture.detectChanges();
    (el.querySelector('[data-testid="debug-skip-bkpt-btn"]') as HTMLButtonElement).click();
    expect(skipped).toBe(true);
    expect(skippedCore).toBe(Core.Cpu1);
    debug.activeCore.set(Core.Cpu0);
    fixture.detectChanges();

    (el.querySelector('[data-testid="debug-gutter-0x02000102"]') as HTMLButtonElement).click();
    expect(toggledAddr).toBe(0x0200_0102);

    vim.setEnabled(true);
    const viewport = el.querySelector('[data-testid="debug-code-viewport"]') as HTMLElement;
    viewport.dispatchEvent(new KeyboardEvent('keydown', { key: 'j', bubbles: true }));
    fixture.detectChanges();
    expect(vim.cursor().line).toBe(1);

    (el.querySelector('[data-testid="debug-mode-decomp"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="debug-disasm"]')?.textContent).toContain('r0 = 1');

    (el.querySelector('[data-testid="debug-mode-source"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="debug-disasm"]')?.textContent).toContain('return 1');
  });
});
