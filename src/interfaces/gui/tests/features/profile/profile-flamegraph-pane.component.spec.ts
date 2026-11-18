import { TestBed } from '@angular/core/testing';
import { Router, provideRouter } from '@angular/router';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { BoardStore } from '../../../src/app/core/stores/board.store';
import { ProfileStore } from '../../../src/app/core/stores/profile.store';
import { ProfileFlamegraphPaneComponent } from '../../../src/app/features/profile/profile-flamegraph-pane.component';

describe('ProfileFlamegraphPaneComponent', () => {
  it('switches Flamegraph vs Icicle, filters symbols, sorts hotspots, and jumps to /debug', async () => {
    TestBed.configureTestingModule({
      providers: [provideRouter([{ path: 'debug', children: [] }])],
    });
    const rpc = TestBed.inject(RpcConnectionStore);
    const board = TestBed.inject(BoardStore);
    const profile = TestBed.inject(ProfileStore);
    const router = TestBed.inject(Router);
    let navigatedUrl = '';
    router.navigate = async (commands, extras) => {
      navigatedUrl = `${commands.join('/')}?symbol=${String(extras?.queryParams?.['symbol'] ?? '')}`;
      return true;
    };

    rpc.connectionState.set('connected');
    board.cpu0ElfSymbols.set([{ name: 'work', address: 0x0200_1200, size: 16, kind: 'func' }]);
    profile.foldedText.set('Reset_Handler;main;work 60\nReset_Handler;main;idle 20');

    const fixture = TestBed.createComponent(ProfileFlamegraphPaneComponent);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('CALL STACK FLAMEGRAPH');
    expect(el.textContent).toContain('TOP SELF-CYCLE HOTSPOTS');
    expect(el.querySelector('[data-testid="profile-selected-frame"]')?.textContent).toContain('work');

    (el.querySelector('[data-testid="profile-mode-icicle"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="profile-mode-icicle"]')?.classList.contains('is-active')).toBe(true);

    const filterInput = el.querySelector('[data-testid="profile-symbol-filter"]') as HTMLInputElement;
    filterInput.value = 'work';
    filterInput.dispatchEvent(new Event('input'));
    fixture.detectChanges();
    expect(el.querySelectorAll('tbody tr.hs-row').length).toBe(1);

    (el.querySelector('[data-testid="hotspot-jump-work"]') as HTMLButtonElement).click();
    await Promise.resolve();
    await fixture.whenStable();
    fixture.detectChanges();
    expect(navigatedUrl).toBe('/debug?symbol=work');
  });
});
