import { TestBed } from '@angular/core/testing';
import { PreferencesStore } from '../../src/app/core/stores/preferences.store';
import { HardwareRouteComponent } from '../../src/app/routes/hardware.route';

describe('HardwareRouteComponent', () => {
  it('renders FITTED PARTS and toggles Board, Debugger, and 3-column Split layouts', () => {
    TestBed.configureTestingModule({});
    const prefs = TestBed.inject(PreferencesStore);
    prefs.setWorkbenchLayout('split');

    const fixture = TestBed.createComponent(HardwareRouteComponent);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;

    expect(el.textContent).toContain('FITTED PARTS');
    expect(el.querySelector('app-hardware-panel-io')).not.toBeNull();
    expect(el.querySelector('app-hardware-hil-faults')).not.toBeNull();
    expect(el.querySelector('app-hardware-mmio')).not.toBeNull();

    const buttons = el.querySelectorAll('[data-testid="hardware-layout-switcher"] button');
    (buttons[0] as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(prefs.prefs().workbenchLayout).toBe('board');
    expect(el.textContent).toContain('FITTED PARTS');
    expect(el.querySelector('app-hardware-panel-io')).not.toBeNull();
    expect(el.querySelector('app-hardware-mmio')).toBeNull();

    (buttons[1] as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(prefs.prefs().workbenchLayout).toBe('debugger');
    expect(el.textContent).toContain('FITTED PARTS');
    expect(el.querySelector('app-hardware-panel-io')).toBeNull();
    expect(el.querySelector('app-hardware-mmio')).not.toBeNull();

    prefs.setWorkbenchLayout('split');
  });
});
