import { TestBed } from '@angular/core/testing';
import { CommandInputComponent } from '../../../src/app/shared/ui/command-input.component';
import { SectionKickerComponent } from '../../../src/app/shared/ui/section-kicker.component';
import { SplitPaneComponent } from '../../../src/app/shared/ui/split-pane.component';
import { StatusDotComponent } from '../../../src/app/shared/ui/status-dot.component';
import { TonalButtonComponent } from '../../../src/app/shared/ui/tonal-button.component';

describe('shared Editorial Slate UI primitives', () => {
  it('renders SectionKickerComponent and StatusDotComponent with input signals', async () => {
    const kickerFixture = TestBed.createComponent(SectionKickerComponent);
    kickerFixture.componentRef.setInput('label', 'WORKSPACE INDEX');
    kickerFixture.autoDetectChanges(true);
    await kickerFixture.whenStable();
    expect(kickerFixture.nativeElement.textContent).toContain('WORKSPACE INDEX');

    const dotFixture = TestBed.createComponent(StatusDotComponent);
    dotFixture.componentRef.setInput('tone', 'nominal');
    dotFixture.componentRef.setInput('label', 'Connected');
    dotFixture.autoDetectChanges(true);
    await dotFixture.whenStable();
    expect(dotFixture.nativeElement.querySelector('.dot.is-nominal')).toBeTruthy();
    expect(dotFixture.nativeElement.textContent).toContain('Connected');
  });

  it('renders TonalButtonComponent, SplitPaneComponent, and CommandInputComponent', async () => {
    const btnFixture = TestBed.createComponent(TonalButtonComponent);
    btnFixture.componentRef.setInput('variant', 'tonal');
    btnFixture.componentRef.setInput('active', true);
    btnFixture.autoDetectChanges(true);
    await btnFixture.whenStable();
    expect(btnFixture.nativeElement.querySelector('button.es-tonal-btn.is-active')).toBeTruthy();

    const paneFixture = TestBed.createComponent(SplitPaneComponent);
    paneFixture.componentRef.setInput('primarySize', '280px');
    paneFixture.componentRef.setInput('persistKey', 'unit-test-split');
    paneFixture.autoDetectChanges(true);
    await paneFixture.whenStable();
    const grid = paneFixture.nativeElement.querySelector('.split-grid') as HTMLElement;
    expect(grid.style.gridTemplateColumns).toContain('280px');

    const handle = paneFixture.nativeElement.querySelector('[data-testid="split-pane-handle"]') as HTMLElement;
    expect(handle).toBeTruthy();
    handle.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight' }));
    await paneFixture.whenStable();
    expect(localStorage.getItem('ra8.split.v1.unit-test-split')).toBe('38.00');
    paneFixture.componentInstance.resetSize();
    expect(localStorage.getItem('ra8.split.v1.unit-test-split')).toBeNull();

    const cmdFixture = TestBed.createComponent(CommandInputComponent);
    let submitted = '';
    cmdFixture.componentInstance.submitted.subscribe((val) => {
      submitted = val;
    });
    cmdFixture.autoDetectChanges(true);
    await cmdFixture.whenStable();
    const input = cmdFixture.nativeElement.querySelector('input') as HTMLInputElement;
    input.value = '>pause';
    input.dispatchEvent(new Event('input'));
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
    await cmdFixture.whenStable();
    expect(cmdFixture.componentInstance.value()).toBe('>pause');
    expect(submitted).toBe('>pause');
  });
});
