import { ChangeDetectionStrategy, Component, signal } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { describe, expect, it } from 'vitest';
import { RpcConnectionStore } from '../../src/app/core/rpc/rpc-connection.store';
import { ExecutionStore } from '../../src/app/core/stores/execution.store';
import { ConnectionPopoverComponent } from '../../src/app/shell/connection-popover.component';

@Component({
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [ConnectionPopoverComponent],
  template: `
    <app-connection-popover
      [open]="open()"
      (closed)="closedCount = closedCount + 1"
      (openConnectManager)="openedManager = true"
    />
  `,
})
class PopoverHostComponent {
  public open = signal(true);
  public closedCount = 0;
  public openedManager = false;
}

describe('ConnectionPopoverComponent', () => {
  it('renders GDB / ctl attach commands, updates GDB port, and toggles Observe mode', async () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const execution = TestBed.inject(ExecutionStore);
    rpc.serverUrl.set('ws://10.0.4.18:4567');
    rpc.connectionState.set('connected');
    rpc.lastHandshakeMs.set(1.2);
    execution.externalSyncCount.set(3);

    const fixture = TestBed.createComponent(PopoverHostComponent);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="popover-gdb-command"]')?.textContent).toContain(
      'target extended-remote 10.0.4.18:3333'
    );
    expect(el.querySelector('[data-testid="popover-ctl-command"]')?.textContent).toContain('ra8_emulator ctl sessions');

    const portInput = el.querySelector('[data-testid="popover-gdb-port-input"]') as HTMLInputElement;
    portInput.value = '4444';
    portInput.dispatchEvent(new Event('input'));
    await fixture.whenStable();
    expect(el.querySelector('[data-testid="popover-gdb-command"]')?.textContent).toContain(
      'target extended-remote 10.0.4.18:4444'
    );

    (el.querySelector('[data-testid="popover-observe-toggle"]') as HTMLButtonElement).click();
    expect(rpc.observeOnly()).toBe(true);

    (el.querySelector('[data-testid="popover-open-connect"]') as HTMLButtonElement).click();
    expect(fixture.componentInstance.openedManager).toBe(true);
    expect(fixture.componentInstance.closedCount).toBe(1);
  });
});
