import { TestBed } from '@angular/core/testing';
import { Core, type RA8RpcClient } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { BoardStore } from '../../../src/app/core/stores/board.store';
import { ConsoleSidebarComponent } from '../../../src/app/features/console/console-sidebar.component';
import type { WatchTriggerAction } from '../../../src/app/features/console/console-model';

describe('ConsoleSidebarComponent', () => {
  it('resolves ELF symbols with getSourceLine file:line lookup and emits Alert+Halt/Marker rules', async () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const board = TestBed.inject(BoardStore);
    board.cpu0ElfName.set('uart_irq_echo.elf');
    board.cpu0HasDwarf.set(true);
    board.cpu0ElfSymbols.set([{ name: 'handle_uart', address: 0x0200_1200, size: 16, kind: 'func' }]);

    rpc.connectionState.set('connected');
    Object.defineProperty(rpc, 'activeClient', {
      configurable: true,
      get: () =>
        ({
          getSourceLine: async (_core: Core) => ({
            found: true,
            pc: 0x0200_1204,
            line: 88,
            path: 'src/uart_irq.c',
          }),
        }) as unknown as RA8RpcClient,
    });

    const fixture = TestBed.createComponent(ConsoleSidebarComponent);
    const added: Array<{ pattern: string; action: WatchTriggerAction; pauseOnMatch: boolean }> = [];
    fixture.componentInstance.addRule.subscribe((evt) => added.push(evt));
    fixture.detectChanges();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('uart_irq_echo.elf');
    expect(el.textContent).toContain('DWARF synced');

    (el.querySelector('[data-testid="console-source-line-btn"]') as HTMLButtonElement).click();
    await Promise.resolve();
    await fixture.whenStable();
    fixture.detectChanges();
    expect(el.textContent).toContain('src/uart_irq.c:88');
    expect(el.textContent).toContain('handle_uart+0x4 · src/uart_irq.c:88');

    (el.querySelector('[data-testid="console-trigger-action-marker"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    const pat = el.querySelector('[data-testid="console-trigger-input"]') as HTMLInputElement;
    pat.value = 'PANIC';
    pat.dispatchEvent(new Event('input'));
    pat.closest('form')!.dispatchEvent(new Event('submit'));
    expect(added).toEqual([{ pattern: 'PANIC', action: 'marker', pauseOnMatch: false }]);
  });
});
