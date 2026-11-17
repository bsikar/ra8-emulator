import { TestBed } from '@angular/core/testing';
import { LaunchIconComponent } from '../../../src/app/features/launch/launch-icons.component';

describe('LaunchIconComponent', () => {
  it('renders crisp SVG glyphs for Launch icons', async () => {
    const fixture = TestBed.createComponent(LaunchIconComponent);
    fixture.componentRef.setInput('name', 'pin');
    fixture.componentRef.setInput('filled', true);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();
    expect(fixture.nativeElement.querySelector('svg')).toBeTruthy();

    fixture.componentRef.setInput('name', 'extensions');
    fixture.autoDetectChanges(true);
    await fixture.whenStable();
    expect(fixture.nativeElement.querySelectorAll('rect').length).toBeGreaterThan(0);
  });
});
