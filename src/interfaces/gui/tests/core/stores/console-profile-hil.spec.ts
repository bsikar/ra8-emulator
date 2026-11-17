import { TestBed } from '@angular/core/testing';
import { Core, EventKind } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { ConsoleStore, MAX_CONSOLE_ENTRIES } from '../../../src/app/core/stores/console.store';
import {
  HardwareHilStore,
  formatFaultSpec,
  splitFirstAtEndpoint,
} from '../../../src/app/core/stores/hardware-hil.store';
import { ProfileStore } from '../../../src/app/core/stores/profile.store';

describe('ConsoleStore, ProfileStore, and HardwareHilStore', () => {
  it('caps ConsoleStore ring buffer at 2000 entries and preserves channel/bytes/virtualNs', () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const consoleStore = TestBed.inject(ConsoleStore);

    for (let i = 0; i < MAX_CONSOLE_ENTRIES + 25; i++) {
      rpc.uart$.next({
        core: Core.Cpu0,
        channel: i % 2,
        virtualNs: BigInt(i * 1000),
        bytes: new TextEncoder().encode(`line-${i}`),
      });
    }

    expect(consoleStore.entries().length).toBe(MAX_CONSOLE_ENTRIES);
    expect(consoleStore.entries()[0]?.text).toBe('line-25');
    expect(consoleStore.channels()).toEqual([0, 1]);

    consoleStore.selectedChannel.set(1);
    expect(consoleStore.filteredEntries().every((e) => e.channel === 1)).toBe(true);
    expect(consoleStore.exportLogText()).toContain('CH1 RX');
  });

  it('tracks Trace timeline ring buffer, stack math, and folded flamegraph in ProfileStore', () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const profileStore = TestBed.inject(ProfileStore);

    rpc.trace$.next({
      core: Core.Cpu0,
      kind: EventKind.RtosSwitch,
      virtualNs: 5000n,
      thread: 0x2000_1000,
      exception: 0,
      name: 'sensor_task',
    });
    expect(profileStore.rtosTasks()[0]?.name).toBe('sensor_task');

    profileStore.foldedText.set('Reset_Handler;main;blink 40\nReset_Handler;main;idle 10');
    expect(profileStore.flamegraph().totalSamples).toBe(50);
    expect(profileStore.flamegraph().hotspot?.name).toBe('blink');
  });

  it('parses first-@ endpoints and formats MODEL@ENDPOINT=MODE fault rules cleanly', () => {
    expect(splitFirstAtEndpoint('gt911@riic1:0x5d')).toEqual({ model: 'gt911', endpoint: 'riic1:0x5d' });
    expect(splitFirstAtEndpoint('c6@uart:sci2')).toEqual({ model: 'c6', endpoint: 'uart:sci2' });
    expect(formatFaultSpec('gt911@riic1:0x5d', 'nack')).toBe('gt911@riic1:0x5d=nack');
    expect(formatFaultSpec('riic1:0x5d', 'timeout')).toBe('@riic1:0x5d=timeout');
    expect(formatFaultSpec('gt911@riic1:0x5d', 'gt911@riic1:0x5d=crc')).toBe('gt911@riic1:0x5d=crc');

    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const hilStore = TestBed.inject(HardwareHilStore);
    rpc.session$.next({ core: Core.Cpu0, kind: EventKind.FaultSet, address: 0x4000_1000 });
    expect(hilStore.events()[0]?.label).toBe('Fault Injected');
  });
});
