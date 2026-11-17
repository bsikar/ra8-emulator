import { TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { RouterTestingHarness } from '@angular/router/testing';
import { appRoutes } from '../../src/app/app.routes';
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
});
