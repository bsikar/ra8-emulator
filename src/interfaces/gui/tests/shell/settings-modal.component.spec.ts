import { TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { SettingsModalComponent } from '../../src/app/shell/settings-modal.component';

describe('SettingsModalComponent', () => {
  beforeEach(() => {
    localStorage.clear();
    HTMLAnchorElement.prototype.click = () => {};
    TestBed.configureTestingModule({
      providers: [provideRouter([])],
    });
  });

  it('renders Session settings dialog with Vim toggle, Appearance schemes, and Probe policy', async () => {
    const fixture = TestBed.createComponent(SettingsModalComponent);
    fixture.componentRef.setInput('open', true);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    const dialog = el.querySelector('[role="dialog"][aria-label="Session settings"]');
    expect(dialog).toBeTruthy();
    expect(el.querySelector('[data-testid="settings-vim-toggle"]')).toBeTruthy();
    expect(el.querySelector('[data-testid="settings-open-extensions"]')).toBeTruthy();

    (el.querySelector('[data-testid="settings-tab-appearance"]') as HTMLButtonElement).click();
    await fixture.whenStable();
    expect(el.querySelector('[data-testid="settings-scheme-preview"]')).toBeTruthy();
    expect(el.querySelector('[data-testid="settings-preview-reg"]')?.textContent).toContain('R3 = 0x00000000');
    expect(el.querySelector('[data-testid="settings-preview-event"]')?.textContent).toContain('[fault]');
    (el.querySelector('[data-testid="scheme-option-nordic-frost"]') as HTMLButtonElement).click();
    await fixture.whenStable();
    expect(document.documentElement.style.getPropertyValue('--es-tok-kw')).toBe('#88a4bf');

    (el.querySelector('[data-testid="settings-tab-probes"]') as HTMLButtonElement).click();
    await fixture.whenStable();
    expect(el.querySelector('[data-testid="settings-probe-identity"]')).toBeTruthy();
    (el.querySelector('[data-testid="settings-rescan-probes"]') as HTMLButtonElement).click();
    await Promise.resolve();
    await fixture.whenStable();
    expect(el.querySelector('[data-testid="settings-probes-list"]')?.textContent).toContain('Offline');
  });
});
