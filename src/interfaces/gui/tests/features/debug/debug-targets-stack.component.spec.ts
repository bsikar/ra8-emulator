import { TestBed } from '@angular/core/testing';
import { Core } from 'ra8-rpc-client';
import { beforeEach, describe, expect, it } from 'vitest';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { DebugStore } from '../../../src/app/core/stores/debug.store';
import { ExecutionStore } from '../../../src/app/core/stores/execution.store';
import { ProfileStore } from '../../../src/app/core/stores/profile.store';
import { DebugTargetsStackComponent } from '../../../src/app/features/debug/debug-targets-stack.component';

describe('DebugTargetsStackComponent', () => {
  beforeEach(() => {
    TestBed.configureTestingModule({});
  });

  it('switches cores, selects stack frame, and arms named/hex breakpoints', async () => {
    const rpc = TestBed.inject(RpcConnectionStore);
    const execution = TestBed.inject(ExecutionStore);
    const debug = TestBed.inject(DebugStore);
    const profile = TestBed.inject(ProfileStore);

    let selectedFrame = -1;
    let armedName = '';
    debug.selectFrame = async (idx: number) => {
      selectedFrame = idx;
      debug.selectedFrameIndex.set(idx);
    };
    debug.addNamedBreakpoint = async (name: string) => {
      armedName = name;
      return { id: 1, address: 0x0200_0100, deferred: true };
    };

    rpc.connectionState.set('connected');
    execution.cpu1Attached.set(true);
    debug.cpu0Backtrace.set({
      core: Core.Cpu0,
      count: 2,
      frames: [
        { pc: 0x0200_0100, interrupted: 0, offset: 0, line: 42, name: 'main', file: 'main.c' },
        { pc: 0x0200_0200, interrupted: 0, offset: 4, line: 10, name: 'Reset_Handler', file: 'startup.c' },
      ],
    });
    profile.cpu0Stack.set({
      core: Core.Cpu0,
      msp: 0x2200_7c00,
      psp: 0x2201_8e00,
      lowMsp: 0x2200_7800,
      lowPsp: 0x2201_8d00,
      hasStack: true,
      base: 0x2200_6000,
      size: 0x2000,
      overflow: 0,
    });

    const fixture = TestBed.createComponent(DebugTargetsStackComponent);
    fixture.detectChanges();
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="debug-core-1"]')).toBeTruthy();
    expect(el.querySelector('[data-testid="debug-stack-watermark"]')?.textContent).toContain('25%');

    (el.querySelector('[data-testid="debug-frame-1"]') as HTMLButtonElement).click();
    expect(selectedFrame).toBe(1);

    (el.querySelector('[data-testid="debug-bp-add-toggle"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    const input = el.querySelector('[data-testid="debug-bp-target-input"]') as HTMLInputElement;
    input.value = 'uart_irq';
    input.dispatchEvent(new Event('input'));
    (el.querySelector('[data-testid="debug-bp-submit-btn"]') as HTMLButtonElement).click();
    await fixture.whenStable();
    expect(armedName).toBe('uart_irq');
  });
});
