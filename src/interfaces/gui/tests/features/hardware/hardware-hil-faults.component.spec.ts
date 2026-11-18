import { TestBed } from '@angular/core/testing';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { HardwareHilStore } from '../../../src/app/core/stores/hardware-hil.store';
import {
  HardwareHilFaultsComponent,
  formatFaultModeRule,
} from '../../../src/app/features/hardware/hardware-hil-faults.component';

describe('HardwareHilFaultsComponent', () => {
  it('formats all 7 fault modes and submits plug and fault injection commands', async () => {
    expect(formatFaultModeRule('disconnected', '')).toBe('disconnected');
    expect(formatFaultModeRule('nack', '12')).toBe('nack:12');
    expect(formatFaultModeRule('stuck', '0xA5')).toBe('stuck:0xA5');
    expect(formatFaultModeRule('garbage', '99')).toBe('garbage:99');
    expect(formatFaultModeRule('slow', '5000')).toBe('slow:5000');
    expect(formatFaultModeRule('stretch', '25000')).toBe('stretch:25000');
    expect(formatFaultModeRule('bus_low', '')).toBe('bus_low');

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
    plugInput.value = 'tmp102@i2c:riic@0x48';
    plugInput.dispatchEvent(new Event('input'));
    plugInput.closest('form')!.dispatchEvent(new Event('submit'));
    await fixture.whenStable();
    expect(plugged).toBe('tmp102@i2c:riic@0x48');

    (el.querySelector('[data-testid="hardware-fault-chip-stretch"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    const paramInput = el.querySelector('[data-testid="hardware-fault-param"]') as HTMLInputElement;
    paramInput.value = '40000';
    paramInput.dispatchEvent(new Event('input'));
    fixture.detectChanges();

    (el.querySelector('[data-testid="hardware-fault-inject-btn"]') as HTMLButtonElement).click();
    expect(injected).toBe('tmp102@i2c:riic@0x48=stretch:40000');
  });
});
