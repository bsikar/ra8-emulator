import { TestBed } from '@angular/core/testing';
import { RewindRouteComponent } from '../../src/app/routes/rewind.route';

describe('RewindRouteComponent', () => {
  it('renders EXECUTION BRANCHES, DAG canvas, and STATE DIFF contracts cleanly', () => {
    TestBed.configureTestingModule({});
    const fixture = TestBed.createComponent(RewindRouteComponent);
    fixture.detectChanges();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('EXECUTION BRANCHES');
    expect(el.textContent).toContain('BRANCH DAG');
    expect(el.textContent).toContain('STATE DIFF');
  });
});
