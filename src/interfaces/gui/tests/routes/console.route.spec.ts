import { TestBed } from '@angular/core/testing';
import { Core } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../src/app/core/rpc/rpc-connection.store';
import { ConsoleStore } from '../../src/app/core/stores/console.store';
import { ExecutionStore } from '../../src/app/core/stores/execution.store';
import { ConsoleRouteComponent } from '../../src/app/routes/console.route';

describe('ConsoleRouteComponent', () => {
  it('preserves UART SERIAL STREAM contract and pauses on matching watch trigger', async () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const consoleStore = TestBed.inject(ConsoleStore);
    const execution = TestBed.inject(ExecutionStore);

    rpc.connectionState.set('connected');
    let paused = false;
    execution.pause = async () => {
      paused = true;
    };

    const fixture = TestBed.createComponent(ConsoleRouteComponent);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('UART SERIAL STREAM');

    const pat = el.querySelector('[data-testid="console-trigger-input"]') as HTMLInputElement;
    pat.value = 'FAULT';
    pat.dispatchEvent(new Event('input'));
    pat.closest('form')!.dispatchEvent(new Event('submit'));
    fixture.detectChanges();

    consoleStore.pushUartEvent({
      core: Core.Cpu0,
      channel: 0,
      virtualNs: 100n,
      bytes: new TextEncoder().encode('HARD FAULT DETECTED'),
    });
    fixture.detectChanges();
    await fixture.whenStable();

    expect(paused).toBe(true);
    expect(el.textContent).toContain('Pause · 1');
  });
});
