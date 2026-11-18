import { TestBed } from '@angular/core/testing';
import { PreferencesStore } from '../../src/app/core/stores/preferences.store';
import { HardwareRouteComponent } from '../../src/app/routes/hardware.route';

describe('HardwareRouteComponent', () => {
  it('renders FITTED PARTS contract and syncs workbench layout switcher', () => {
    TestBed.configureTestingModule({});
    const prefs = TestBed.inject(PreferencesStore);

    const fixture = TestBed.createComponent(HardwareRouteComponent);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('FITTED PARTS');

    const buttons = el.querySelectorAll('[data-testid="hardware-layout-switcher"] button');
    (buttons[0] as HTMLButtonElement).click();
    expect(prefs.prefs().workbenchLayout).toBe('board');
  });
});
