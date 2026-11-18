import { TestBed } from '@angular/core/testing';
import { RewindRouteComponent } from '../../src/app/routes/rewind.route';

describe('RewindRouteComponent', () => {
  it('renders EXECUTION BRANCHES, BRANCH DAG, STATE DIFF, and transport controls cleanly', () => {
    TestBed.configureTestingModule({});
    const fixture = TestBed.createComponent(RewindRouteComponent);
    fixture.detectChanges();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('EXECUTION BRANCHES');
    expect(el.textContent).toContain('BRANCH DAG');
    expect(el.textContent).toContain('STATE DIFF');
    expect(el.querySelector('[data-testid="rewind-step-back-btn"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="rewind-diff-swap-btn"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="rewind-export-tar-btn"]')).not.toBeNull();
  });
});
