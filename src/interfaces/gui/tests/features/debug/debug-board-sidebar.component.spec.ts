import { TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { Core, findBoardPreset } from 'ra8-rpc-client';
import { beforeEach, describe, expect, it } from 'vitest';
import { appRoutes } from '../../../src/app/app.routes';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { BoardStore } from '../../../src/app/core/stores/board.store';
import { ConsoleStore } from '../../../src/app/core/stores/console.store';
import { DebugBoardSidebarComponent } from '../../../src/app/features/debug/debug-board-sidebar.component';

describe('DebugBoardSidebarComponent', () => {
  beforeEach(() => {
    TestBed.configureTestingModule({ providers: [provideRouter(appRoutes)] });
  });

  it('renders headless card when panel is null and forwards serial TX input', async () => {
    const rpc = TestBed.inject(RpcConnectionStore);
    const board = TestBed.inject(BoardStore);
    const consoleStore = TestBed.inject(ConsoleStore);

    rpc.connectionState.set('connected');
    const headless = findBoardPreset('fpb-ra8e1')!;
    board.selectedPreset.set(headless);
    board.boardProfile.set(headless.profile);

    let sent = '';
    consoleStore.sendInput = async (raw: string) => {
      sent = raw;
      return true;
    };
    consoleStore.pushUartEvent({ core: Core.Cpu0, channel: 8, virtualNs: 100n, bytes: new TextEncoder().encode('boot ok') });

    const fixture = TestBed.createComponent(DebugBoardSidebarComponent);
    fixture.detectChanges();
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('Headless target profile');
    expect(el.textContent).toContain('boot ok');

    const txInput = el.querySelector('[data-testid="debug-serial-tx-input"]') as HTMLInputElement;
    txInput.value = 'status';
    txInput.dispatchEvent(new Event('input'));
    txInput.closest('form')!.dispatchEvent(new Event('submit'));
    await fixture.whenStable();
    expect(sent).toBe('status');
  });
});
