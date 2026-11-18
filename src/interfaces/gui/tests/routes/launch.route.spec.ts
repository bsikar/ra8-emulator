import { TestBed } from '@angular/core/testing';
import { provideRouter, Router } from '@angular/router';
import { appRoutes } from '../../src/app/app.routes';
import { WorkspaceStore } from '../../src/app/core/stores/workspace.store';
import { LaunchRouteComponent } from '../../src/app/routes/launch.route';

describe('LaunchRouteComponent', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('shows honest empty state on first boot without fake workspaces', async () => {
    TestBed.configureTestingModule({
      providers: [provideRouter(appRoutes)],
    });
    const fixture = TestBed.createComponent(LaunchRouteComponent);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="launch-empty-state"]')).toBeTruthy();
    expect(el.querySelector('[data-testid="launch-ws-input"]')).toBeTruthy();
    expect(el.textContent).toContain('Connect Target Session');
  });

  it('renders populated workspace index, toggles pin/remove, and switches into > command mode', async () => {
    TestBed.configureTestingModule({
      providers: [provideRouter(appRoutes)],
    });
    const store = TestBed.inject(WorkspaceStore);
    store.recordRecentWorkspace({
      id: 'ws-p1',
      name: 'RA8P1 Vision HMI',
      path: '~/work/ra8p1',
      wsUrl: 'ws://127.0.0.1:4567',
      pinned: false,
      targetModel: 'EK-RA8P1',
      archSummary: 'Cortex-M85 + M33 + Ethos-U55',
      modeLabel: 'Emulator',
      artifactSummary: 'ek_ra8p1.board',
      checkpointCount: 42,
    });

    const fixture = TestBed.createComponent(LaunchRouteComponent);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="workspace-row-ws-p1"]')).toBeTruthy();
    expect(el.querySelector('[data-testid="launch-empty-state"]')).toBeNull();

    const pinBtn = el.querySelector('[data-testid="workspace-pin-ws-p1"]') as HTMLButtonElement;
    pinBtn.click();
    await fixture.whenStable();
    expect(store.recentWorkspaces()[0]?.pinned).toBe(true);

    const searchInput = el.querySelector('[data-testid="launch-search-input"]') as HTMLInputElement;
    searchInput.value = '>';
    searchInput.dispatchEvent(new Event('input'));
    await fixture.whenStable();

    expect(el.querySelector('[data-testid="launch-command-card"]')).toBeTruthy();
    expect(el.textContent).toContain('SESSION & WORKSPACE COMMANDS');
    expect(el.textContent).toContain('HARDWARE PROBES & BOARD COMPOSER');
    expect(el.textContent).toContain('IDE & EXTENSIONS');

    const backBtn = el.querySelector('[data-testid="launch-cmd-back"]') as HTMLButtonElement;
    backBtn.click();
    await fixture.whenStable();
    expect(el.querySelector('[data-testid="workspace-index-card"]')).toBeTruthy();
  });

  it('creates a real workspace through + New Workspace dialog', async () => {
    TestBed.configureTestingModule({
      providers: [provideRouter(appRoutes)],
    });
    const store = TestBed.inject(WorkspaceStore);
    const fixture = TestBed.createComponent(LaunchRouteComponent);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    const newBtn = el.querySelector('[data-testid="launch-action-new"]') as HTMLButtonElement;
    newBtn.click();
    await fixture.whenStable();

    expect(el.querySelector('[data-testid="new-workspace-dialog"]')).toBeTruthy();
    const presetBtn = el.querySelector('[data-testid="preset-ra8p1"]') as HTMLButtonElement;
    presetBtn.click();
    await fixture.whenStable();

    const createBtn = el.querySelector('[data-testid="new-ws-create-btn"]') as HTMLButtonElement;
    createBtn.click();
    await fixture.whenStable();

    expect(store.recentWorkspaces().length).toBe(1);
    expect(store.recentWorkspaces()[0]?.targetModel).toBe('RA8P1');
  });

  it('exits > Command Mode on window Escape even when a command button has focus', async () => {
    TestBed.configureTestingModule({
      providers: [provideRouter(appRoutes)],
    });
    const fixture = TestBed.createComponent(LaunchRouteComponent);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    const searchInput = el.querySelector('[data-testid="launch-search-input"]') as HTMLInputElement;
    searchInput.value = '>';
    searchInput.dispatchEvent(new Event('input'));
    await fixture.whenStable();
    expect(el.querySelector('[data-testid="launch-command-card"]')).toBeTruthy();

    const cmdBtn = el.querySelector('[data-testid="launch-cmd-new-workspace"]') as HTMLButtonElement;
    cmdBtn.focus();
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', cancelable: true }));
    await fixture.whenStable();
    expect(el.querySelector('[data-testid="launch-command-card"]')).toBeNull();
  });

  it('navigates to /connect when clicking Connect Remote', async () => {
    TestBed.configureTestingModule({
      providers: [provideRouter(appRoutes)],
    });
    const router = TestBed.inject(Router);
    const fixture = TestBed.createComponent(LaunchRouteComponent);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const btn = fixture.nativeElement.querySelector('[data-testid="launch-action-connect"]') as HTMLButtonElement;
    btn.click();
    await fixture.whenStable();
    expect(router.url).toBe('/connect');
  });

  it('navigates to /open and /import from launch action buttons', async () => {
    TestBed.configureTestingModule({
      providers: [provideRouter(appRoutes)],
    });
    const router = TestBed.inject(Router);
    const fixture = TestBed.createComponent(LaunchRouteComponent);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    (fixture.nativeElement.querySelector('[data-testid="launch-action-open"]') as HTMLButtonElement).click();
    await fixture.whenStable();
    expect(router.url).toBe('/open');

    await router.navigateByUrl('/launch');
    (fixture.nativeElement.querySelector('[data-testid="launch-action-import"]') as HTMLButtonElement).click();
    await fixture.whenStable();
    expect(router.url).toBe('/import');
  });
});
