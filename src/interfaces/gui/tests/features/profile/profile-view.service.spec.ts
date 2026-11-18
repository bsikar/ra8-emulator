import { TestBed } from '@angular/core/testing';
import { Core, EventKind } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { ExecutionStore } from '../../../src/app/core/stores/execution.store';
import { ProfileStore } from '../../../src/app/core/stores/profile.store';
import { ALL_THREADS_FILTER, ProfileViewService } from '../../../src/app/features/profile/profile-view.service';

describe('ProfileViewService', () => {
  it('switches cores/threads, manages [A, B] brush windows, exports .folded, and clears state', async () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const execution = TestBed.inject(ExecutionStore);
    const profile = TestBed.inject(ProfileStore);
    const view = TestBed.inject(ProfileViewService);

    rpc.connectionState.set('connected');
    execution.cpu1Attached.set(true);
    profile.pushTraceEvent({
      core: Core.Cpu0,
      kind: EventKind.RtosSwitch,
      virtualNs: 100n,
      thread: 0x2000_1100,
      exception: 0,
      name: 'sensor_task',
    });

    const calls: string[] = [];
    profile.captureFolded = async (core, thread, fromNs, toNs) => {
      calls.push(`${core}:${thread}:${fromNs}:${toNs}`);
      profile.foldedText.set('Reset_Handler;sensor_task 40');
      return 'Reset_Handler;sensor_task 40';
    };

    await view.selectThreadFilter(0x2000_1100);
    await view.setBrushRange({ fromNs: 100n, toNs: 500n }, true);
    expect(calls[calls.length - 1]).toBe(`0:${0x2000_1100}:100:500`);
    expect(view.brushSummary()).toContain('40 samples');

    await view.resetToFullRun();
    expect(view.brushRange()).toBeNull();
    expect(calls[calls.length - 1]).toContain(`0:${0x2000_1100}:0:`);

    const prevClick = HTMLAnchorElement.prototype.click;
    HTMLAnchorElement.prototype.click = () => undefined;
    try {
      const ok = await view.exportFolded();
      expect(ok).toBe(true);
    } finally {
      HTMLAnchorElement.prototype.click = prevClick;
    }

    view.clearAll();
    expect(profile.foldedText()).toBe('');
    expect(view.threadFilter()).toBe(ALL_THREADS_FILTER);
  });
});
