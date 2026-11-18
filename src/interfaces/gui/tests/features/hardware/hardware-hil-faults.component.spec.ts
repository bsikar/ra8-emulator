import { TestBed } from '@angular/core/testing';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { HardwareHilStore } from '../../../src/app/core/stores/hardware-hil.store';
import { HardwareHilFaultsComponent } from '../../../src/app/features/hardware/hardware-hil-faults.component';

describe('HardwareHilFaultsComponent', () => {
  it('submits plug and fault injection commands when connected and editable', async () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const hil = TestBed.inject(HardwareHilStore);

    rpc.connectionState.set('connected');
    rpc.observeOnly.set(false);
    let plugged = '';
    let injected = '';
    hil.plugPart = async (spec: string) => {
      plugged = spec;
      return true;
    };
    hil.injectFault = async (part: string, rule: string) => {
      injected = `${part}=${rule}`;
      return true;
    };

    const fixture = TestBed.createComponent(HardwareHilFaultsComponent);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('FITTED PARTS');

    const plugInput = el.querySelector('[data-testid="hardware-plug-input"]') as HTMLInputElement;
    plugInput.value = 'tmp102@sci3:0x48';
    plugInput.dispatchEvent(new Event('input'));
    plugInput.closest('form')!.dispatchEvent(new Event('submit'));
    await fixture.whenStable();
    expect(plugged).toBe('tmp102@sci3:0x48');

    (el.querySelector('[data-testid="hardware-fault-inject-btn"]') as HTMLButtonElement).click();
    expect(injected).toBe('tmp102@sci3:0x48=nack');
  });
});
