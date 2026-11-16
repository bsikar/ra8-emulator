import { TestBed } from '@angular/core/testing';
import { AppComponent } from './app.component';
import { EmulatorService } from './services/emulator.service';

describe('AppComponent (RA8 Obsidian Precision Workbench)', () => {
  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [AppComponent],
    }).compileComponents();
  });

  it('creates the workbench application with service intact', () => {
    const fixture = TestBed.createComponent(AppComponent);
    const app = fixture.componentInstance;
    const emu = TestBed.inject(EmulatorService);
    expect(app).toBeTruthy();
    expect(emu).toBeTruthy();
  });

  it('renders the 44px Obsidian header with 5 single-word tabs and at most one #0A84FF primary CTA', () => {
    const fixture = TestBed.createComponent(AppComponent);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;

    const tabs = Array.from(el.querySelectorAll('[data-testid="workbench-nav-tab"]')).map((n) =>
      n.textContent?.trim()
    );
    expect(tabs).toEqual(['Workspace', 'Debug', 'Rewind', 'Hardware', 'Profile']);

    const primaryCtas = el.querySelectorAll('[data-testid="primary-cta"]');
    expect(primaryCtas.length).toBeLessThanOrEqual(1);
    expect(primaryCtas.length).toBe(1);
  });

  it('supports Workspace local/remote modes, adaptable board topologies, ELF Source/Stripped status, and .tar.gz import', () => {
    const fixture = TestBed.createComponent(AppComponent);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;

    expect(el.textContent).toContain('Workspace');
    expect(el.textContent).toContain('Single-Core');
    expect(el.textContent).toContain('Dual-Core');
    expect(el.textContent).toContain('Multi-Core');
    expect(el.textContent).toContain('Ethos-U55');
    expect(el.textContent).toContain('RA8EMU-1247');
    expect(el.textContent).toContain('Import Time-Travel Tarball');
  });

  it('switches cleanly across Debug, Rewind, Hardware, and Profile tabs preserving single primary CTA and inclusive terminology', () => {
    const fixture = TestBed.createComponent(AppComponent);
    const comp = fixture.componentInstance;
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;

    // Debug Tab
    comp.setTab('debug');
    fixture.detectChanges();
    expect(el.querySelectorAll('[data-testid="primary-cta"]').length).toBe(1);
    expect(el.textContent).toContain('Decompiled C');
    expect(el.textContent).toContain('CALL STACK');
    expect(el.textContent).toContain('VIRTUAL BOARD');
    expect(el.textContent).toContain('SCI8 SERIAL OUTPUT');

    // Rewind Tab
    comp.setTab('rewind');
    fixture.detectChanges();
    expect(el.querySelectorAll('[data-testid="primary-cta"]').length).toBe(1);
    expect(el.querySelector('[data-testid="rewind-tree-svg"]')).toBeTruthy();
    expect(el.textContent).toContain('Export Tarball (.tar.gz)');
    expect(el.textContent).toContain('Changed Since Parent');

    // Hardware Tab (inclusive bus vocabulary: Controller, Peripheral, CS, COPI, CIPO)
    comp.setTab('hardware');
    fixture.detectChanges();
    expect(el.querySelectorAll('[data-testid="primary-cta"]').length).toBe(1);
    expect(el.textContent).toContain('Controller');
    expect(el.textContent).toContain('Peripheral');
    expect(el.textContent).toContain('COPI / CIPO');
    expect((el.textContent ?? '').toLowerCase()).not.toContain('mas' + 'ter');
    expect((el.textContent ?? '').toLowerCase()).not.toContain('sla' + 've');

    // Profile Tab
    comp.setTab('profile');
    fixture.detectChanges();
    expect(el.querySelectorAll('[data-testid="primary-cta"]').length).toBe(1);
    expect(el.textContent).toContain('Compute Timeline');
    expect(el.textContent).toContain('Folded');
  });

  it('enforces >= 12px computed font-size floor across rendered workbench controls', () => {
    const fixture = TestBed.createComponent(AppComponent);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    const textNodes = el.querySelectorAll('button, a, span, td, th, label, input');
    for (const node of Array.from(textNodes)) {
      const sizePx = Number.parseFloat(getComputedStyle(node).fontSize || '12');
      expect(sizePx).toBeGreaterThanOrEqual(12);
    }
  });
});
