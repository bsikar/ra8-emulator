import { TestBed } from '@angular/core/testing';
import { Core, EventKind } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { ProfileStore } from '../../../src/app/core/stores/profile.store';
import { ProfileTimelineCanvasComponent } from '../../../src/app/features/profile/profile-timeline-canvas.component';
import { ProfileViewService } from '../../../src/app/features/profile/profile-view.service';

describe('ProfileTimelineCanvasComponent', () => {
  it('renders trace slice telemetry, switches Brush/Pan mode, zooms, and forwards Capture Range', async () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const profile = TestBed.inject(ProfileStore);
    const view = TestBed.inject(ProfileViewService);
    rpc.connectionState.set('connected');
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

    (el.querySelector('[data-testid="timeline-mode-pan"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="timeline-mode-pan"]')?.classList.contains('is-active')).toBe(true);

    (el.querySelector('[data-testid="timeline-mode-brush"]') as HTMLButtonElement).click();
    (el.querySelector('[data-testid="timeline-zoom-in"]') as HTMLButtonElement).click();
    fixture.detectChanges();

    (el.querySelector('[data-testid="profile-capture-btn"]') as HTMLButtonElement).click();
    await fixture.whenStable();
    expect(capturedRange).toBe('0..1000000');
    expect(view.brushRange()).toEqual({ fromNs: 0n, toNs: 1000000n });
  });
});
