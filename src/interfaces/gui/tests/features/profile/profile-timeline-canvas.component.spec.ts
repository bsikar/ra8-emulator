import { TestBed } from '@angular/core/testing';
import { Core, EventKind } from 'ra8-rpc-client';
import { ProfileStore } from '../../../src/app/core/stores/profile.store';
import { ProfileTimelineCanvasComponent } from '../../../src/app/features/profile/profile-timeline-canvas.component';

describe('ProfileTimelineCanvasComponent', () => {
  it('renders trace slice telemetry and forwards Capture Range arguments to ProfileStore', () => {
    TestBed.configureTestingModule({});
    const profile = TestBed.inject(ProfileStore);
    profile.pushTraceEvent({
      core: Core.Cpu0,
      kind: EventKind.RtosSwitch,
      virtualNs: 2000n,
      thread: 1,
      exception: 0,
      name: 'sensor',
    });

    let capturedRange = '';
    profile.captureFolded = async (_core, _thread, fromNs, toNs) => {
      capturedRange = `${(fromNs ?? 0n).toString()}..${(toNs ?? 0n).toString()}`;
      return '';
    };

    const fixture = TestBed.createComponent(ProfileTimelineCanvasComponent);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('CONTEXT-SWITCH TIMELINE');

    (el.querySelector('[data-testid="profile-capture-btn"]') as HTMLButtonElement).click();
    expect(capturedRange).toBe('0..1000000');
  });
});
