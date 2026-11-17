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
  });
});
