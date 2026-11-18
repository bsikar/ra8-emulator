import { TestBed } from '@angular/core/testing';
import { Core } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { BoardStore } from '../../../src/app/core/stores/board.store';
import { ConsoleStore } from '../../../src/app/core/stores/console.store';
import { ConsoleStreamComponent } from '../../../src/app/features/console/console-stream.component';

describe('ConsoleStreamComponent', () => {
  it('renders ASCII/Hex modes, decodes inline ELF symbols, and sends TX commands', async () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const board = TestBed.inject(BoardStore);
    const consoleStore = TestBed.inject(ConsoleStore);

    rpc.connectionState.set('connected');
    board.cpu0ElfSymbols.set([{ name: 'echo_loop', address: 0x0200_0400, size: 16, kind: 'func' }]);
    consoleStore.pushUartEvent({
      core: Core.Cpu0,
      channel: 8,
      virtualNs: 5_000_000n,
      bytes: new TextEncoder().encode('jump 0x02000404 ok'),
    });

    let sentText = '';
    consoleStore.sendInput = async (raw: string) => {
      sentText = raw;
      return true;
    };

    const fixture = TestBed.createComponent(ConsoleStreamComponent);
    fixture.detectChanges();
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('[echo_loop+0x4]');

    (el.querySelector('[data-testid="console-mode-hex"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(el.textContent).toContain('6a 75 6d 70');

    const tx = el.querySelector('[data-testid="console-tx-input"]') as HTMLInputElement;
    tx.value = 'ping';
    tx.dispatchEvent(new Event('input'));
    tx.closest('form')!.dispatchEvent(new Event('submit'));
    expect(sentText).toBe('ping');
  });
});
