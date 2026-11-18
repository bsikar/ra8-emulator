import { TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { Core } from 'ra8-rpc-client';
import { beforeEach, describe, expect, it } from 'vitest';
import { appRoutes } from '../../src/app/app.routes';
import { RpcConnectionStore } from '../../src/app/core/rpc/rpc-connection.store';
import { DebugStore } from '../../src/app/core/stores/debug.store';
import { ExecutionStore } from '../../src/app/core/stores/execution.store';
import { PreferencesStore } from '../../src/app/core/stores/preferences.store';
import { DebugRouteComponent } from '../../src/app/routes/debug.route';

describe('DebugRouteComponent', () => {
  beforeEach(() => {
    localStorage.clear();
    TestBed.configureTestingModule({ providers: [provideRouter(appRoutes)] });
  });

  it('switches persisted Board/Debugger/Split layout and preserves core register & observe selectors', async () => {
    const rpc = TestBed.inject(RpcConnectionStore);
    const debug = TestBed.inject(DebugStore);
    const execution = TestBed.inject(ExecutionStore);
    const prefs = TestBed.inject(PreferencesStore);

    rpc.connectionState.set('connected');
    rpc.setObserveOnly(true);
    debug.cpu0Registers.set({ pc: 0x0200_0100, sp: 0x2200_4000 });
    execution.executionStatus.set('halted');

    const fixture = TestBed.createComponent(DebugRouteComponent);
    fixture.detectChanges();
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('CORE REGISTERS');
    expect(el.querySelector('[data-reg="pc"]')?.textContent).toContain('0x02000100');
    expect(el.querySelector('[data-testid="debug-observe-pill"]')).toBeTruthy();
    expect(el.querySelector('[data-testid="debug-disasm"]')).toBeTruthy();

    (el.querySelector('[data-testid="layout-debugger-btn"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(prefs.prefs().workbenchLayout).toBe('debugger');
    expect(el.querySelector('[data-testid="debug-serial-tx-input"]')).toBeNull();

    (el.querySelector('[data-testid="layout-split-btn"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(prefs.prefs().workbenchLayout).toBe('split');
    expect(el.querySelector('[data-testid="debug-serial-tx-input"]')).toBeTruthy();

    let steppedCore = Core.Cpu0;
    execution.step = async (core = Core.Cpu0) => {
      steppedCore = core;
    };
    rpc.setObserveOnly(false);
    debug.activeCore.set(Core.Cpu1);
    fixture.detectChanges();
    (el.querySelector('[data-testid="debug-step-btn"]') as HTMLButtonElement).click();
    expect(steppedCore).toBe(Core.Cpu1);
  });
});
