import { TestBed } from '@angular/core/testing';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { ProfileStore } from '../../../src/app/core/stores/profile.store';
import { ProfileFlamegraphPaneComponent } from '../../../src/app/features/profile/profile-flamegraph-pane.component';

describe('ProfileFlamegraphPaneComponent', () => {
  it('switches Flamegraph vs Icicle layouts and displays sorted hotspots', () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const profile = TestBed.inject(ProfileStore);
    rpc.connectionState.set('connected');
    profile.foldedText.set('Reset_Handler;main;work 60\nReset_Handler;main;idle 20');

    const fixture = TestBed.createComponent(ProfileFlamegraphPaneComponent);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('TOP HOTSPOTS');
    expect(el.textContent).toContain('work');

    (el.querySelector('[data-testid="profile-mode-icicle"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="profile-mode-icicle"]')?.classList.contains('is-active')).toBe(true);
  });
});
