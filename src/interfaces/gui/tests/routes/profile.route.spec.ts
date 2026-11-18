import { TestBed } from '@angular/core/testing';
import { ProfileRouteComponent } from '../../src/app/routes/profile.route';

describe('ProfileRouteComponent', () => {
  it('renders METRICS & STACKS, CONTEXT-SWITCH TIMELINE, and FOLDED STACK PROFILE', () => {
    TestBed.configureTestingModule({});
    const fixture = TestBed.createComponent(ProfileRouteComponent);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('METRICS & STACKS');
    expect(el.textContent).toContain('CONTEXT-SWITCH TIMELINE');
    expect(el.textContent).toContain('FOLDED STACK PROFILE');
  });
});
