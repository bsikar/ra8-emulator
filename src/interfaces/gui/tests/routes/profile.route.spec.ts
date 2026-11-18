import { TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { ProfileRouteComponent } from '../../src/app/routes/profile.route';

describe('ProfileRouteComponent', () => {
  it('renders top filter bar, METRICS & STACKS, CONTEXT-SWITCH TIMELINE, and CALL STACK FLAMEGRAPH', () => {
    TestBed.configureTestingModule({
      providers: [provideRouter([])],
    });
    const fixture = TestBed.createComponent(ProfileRouteComponent);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="profile-top-bar"]')).not.toBeNull();
    expect(el.textContent).toContain('CPU0 · Cortex-M85');
    expect(el.textContent).toContain('METRICS & STACKS');
    expect(el.textContent).toContain('CONTEXT-SWITCH TIMELINE');
    expect(el.textContent).toContain('CALL STACK FLAMEGRAPH');
  });
});
