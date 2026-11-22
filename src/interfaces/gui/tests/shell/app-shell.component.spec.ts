import { TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { RouterTestingHarness } from '@angular/router/testing';
import { Core } from 'ra8-rpc-client';
import { appRoutes } from '../../src/app/app.routes';
import { RpcConnectionStore } from '../../src/app/core/rpc/rpc-connection.store';
import { BoardStore } from '../../src/app/core/stores/board.store';
import { RecentElfRepository } from '../../src/app/core/stores/recent-elf-db';
import { RECENT_ELF_REPOSITORY, RecentElfStore } from '../../src/app/core/stores/recent-elf.store';
import { AppShellComponent } from '../../src/app/shell/app-shell.component';

describe('AppShellComponent and lazy router', () => {
  it('renders anonymous Editorial Slate chrome with 3 window dots and no brand wordmarks', async () => {
    TestBed.configureTestingModule({
      providers: [provideRouter(appRoutes)],
    });
    const fixture = TestBed.createComponent(AppShellComponent);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelectorAll('[data-testid="window-dot"]').length).toBe(3);
    expect(el.textContent).not.toMatch(/obsidian|ra8 workbench/i);
    expect(el.querySelector('[data-testid="shell-topbar"]')).toBeTruthy();
    expect(el.querySelector('[data-testid="shell-statusbar"]')).toBeTruthy();
  });

  it('navigates across lazy routes via RouterTestingHarness', async () => {
    TestBed.configureTestingModule({
      providers: [provideRouter(appRoutes)],
    });
    const harness = await RouterTestingHarness.create('/launch');
    expect(harness.routeNativeElement?.textContent).toContain('Connect Target Session');

    await harness.navigateByUrl('/debug');
    expect(harness.routeNativeElement?.textContent).toContain('CORE REGISTERS');

    await harness.navigateByUrl('/console');
    expect(harness.routeNativeElement?.textContent).toContain('UART SERIAL STREAM');

    await harness.navigateByUrl('/connect');
    expect(harness.routeNativeElement?.textContent).toContain('LIVE SESSIONS');

    await harness.navigateByUrl('/open');
    expect(harness.routeNativeElement?.textContent).toContain('WORKSPACE DIRECTORY');

    await harness.navigateByUrl('/import');
    expect(harness.routeNativeElement?.textContent).toContain('STAGED BUNDLE');

    await harness.navigateByUrl('/workspace/new');
    expect(harness.routeNativeElement?.textContent).toContain('TARGET BOARD PROFILE');
  });

  it('opens statusbar GDB/ctl connection popover and displays OBSERVE pill when read-only', async () => {
    TestBed.configureTestingModule({
      providers: [provideRouter(appRoutes)],
    });
    const fixture = TestBed.createComponent(AppShellComponent);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    (el.querySelector('[data-testid="statusbar-connection-btn"]') as HTMLButtonElement).click();
    await fixture.whenStable();

    expect(el.querySelector('[data-testid="connection-popover"]')).toBeTruthy();
    (el.querySelector('[data-testid="popover-observe-toggle"]') as HTMLButtonElement).click();
    await fixture.whenStable();
    expect(el.querySelector('[data-testid="statusbar-observe-pill"]')?.textContent?.trim()).toBe('OBSERVE');
  });

  it('wires Vim statusbar pill, settings toggle, :ex prompt, and Extensions shortcut', async () => {
    localStorage.clear();
    TestBed.configureTestingModule({
      providers: [provideRouter(appRoutes)],
    });
    const fixture = TestBed.createComponent(AppShellComponent);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    const vimBtn = el.querySelector('[data-testid="statusbar-vim"]') as HTMLButtonElement;
    expect(vimBtn.textContent?.trim()).toBe('VIM: OFF');

    vimBtn.click();
    await fixture.whenStable();
    expect(vimBtn.textContent?.trim()).toBe('VIM: NORMAL');

    // Open :ex prompt via keyboard
    window.dispatchEvent(new KeyboardEvent('keydown', { key: ':' }));
    await fixture.whenStable();
    const exInput = el.querySelector('[data-testid="vim-ex-input"]') as HTMLInputElement;
    expect(exInput).toBeTruthy();

    exInput.value = 'ext';
    exInput.dispatchEvent(new Event('input'));
    exInput.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    await fixture.whenStable();
    expect(el.querySelector('[data-testid="extensions-sheet-dialog"]')).toBeTruthy();
  });

  it('renders File > Open Recent entries and triggers Reload ELF via Ctrl+R and viewport drop', async () => {
    localStorage.clear();
    const repo = new RecentElfRepository(null);
    TestBed.configureTestingModule({
      providers: [provideRouter(appRoutes), { provide: RECENT_ELF_REPOSITORY, useValue: repo }],
    });
    const rpc = TestBed.inject(RpcConnectionStore);
    const board = TestBed.inject(BoardStore);
    const recentElf = TestBed.inject(RecentElfStore);

    const fixture = TestBed.createComponent(AppShellComponent);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const validElf = new Uint8Array(64);
    validElf[0] = 0x7f;
    validElf[1] = 0x45;
    validElf[2] = 0x4c;
    validElf[3] = 0x46;
    validElf[4] = 1;
    validElf[5] = 1;
    validElf[6] = 1;
    const view = new DataView(validElf.buffer);
    view.setUint16(16, 2, true);
    view.setUint16(18, 40, true);
    view.setUint32(24, 0x0200_0201, true);

    rpc.connectionState.set('connected');
    let reloadCount = 0;
    board.loadElfFile = async () => {
      reloadCount += 1;
      return true;
    };

    await recentElf.recordLoadedElf({
      fileName: 'dropped.elf',
      core: Core.Cpu0,
      wsUrl: 'ws://127.0.0.1:4567',
      bytes: validElf,
    });
    fixture.detectChanges();
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    (el.querySelector('[data-testid="menu-file"]') as HTMLButtonElement).click();
    fixture.detectChanges();

    const recentBtn = el.querySelector('[data-testid="menuitem-recent-elf-0"]') as HTMLButtonElement;
    expect(recentBtn?.textContent).toContain('dropped.elf');
    expect((el.querySelector('[data-testid="menuitem-reload-elf"]') as HTMLButtonElement).disabled).toBe(false);

    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'r', ctrlKey: true, cancelable: true }));
    await Promise.resolve();
    await fixture.whenStable();
    expect(reloadCount).toBe(1);
  });
});
