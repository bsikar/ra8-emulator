import { TestBed } from '@angular/core/testing';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { RewindStore } from '../../../src/app/core/stores/rewind.store';
import { RewindTransportBarComponent } from '../../../src/app/features/rewind/rewind-transport-bar.component';

describe('RewindTransportBarComponent', () => {
  it('normalizes seek targets, renders fork banner on pendingForkPrompt, and confirms fork', async () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const rewind = TestBed.inject(RewindStore);

    rpc.connectionState.set('connected');
    rpc.observeOnly.set(false);
    let sought = '';
    let confirmed = false;
    rewind.seekTo = async (target: string) => {
      sought = target;
      return true;
    };
    rewind.confirmFork = async () => {
      confirmed = true;
      rewind.pendingForkPrompt.set(false);
      return true;
    };

    const fixture = TestBed.createComponent(RewindTransportBarComponent);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;

    const input = el.querySelector('[data-testid="rewind-seek-input"]') as HTMLInputElement;
    input.value = '@250us';
    input.dispatchEvent(new Event('input'));
    input.closest('form')!.dispatchEvent(new Event('submit'));
    expect(sought).toBe('250us');

    rewind.pendingForkPrompt.set(true);
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="rewind-fork-banner"]')).not.toBeNull();
    (el.querySelector('[data-testid="rewind-confirm-fork"]') as HTMLButtonElement).click();
    expect(confirmed).toBe(true);
  });
});
