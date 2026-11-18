import { Core, EventKind } from 'ra8-rpc-client';
import {
  buildExecutionSlices,
  hitTestTimelineSlice,
  zoomTimelineWindow,
} from '../../../src/app/features/profile/timeline-model';

describe('timeline-model', () => {
  it('builds nested ISR and RTOS task slices and hit-tests coordinates', () => {
    const built = buildExecutionSlices([
      { id: 1, core: Core.Cpu0, kind: EventKind.RtosSwitch, virtualNs: 100n, thread: 1, exception: 0, name: 'worker' },
      { id: 2, core: Core.Cpu0, kind: EventKind.IsrEnter, virtualNs: 300n, thread: 1, exception: 15, name: 'SysTick' },
      { id: 3, core: Core.Cpu0, kind: EventKind.IsrLeave, virtualNs: 450n, thread: 1, exception: 15, name: '' },
      { id: 4, core: Core.Cpu0, kind: EventKind.RtosIdle, virtualNs: 900n, thread: 0, exception: 0, name: 'IDLE' },
    ], 1100n);

    expect(built.slices.map((s) => `${s.kind}:${s.label}`)).toEqual([
      'thread:worker',
      'isr:SysTick',
      'thread:worker',
      'idle:IDLE',
    ]);
    expect(built.utilization.cpu0ActivePct).toBe(80);

    const hit = hitTestTimelineSlice(built.slices, 100n, 1100n, Core.Cpu0, 250, 1000);
    expect(hit?.kind).toBe('isr');

    const zoomed = zoomTimelineWindow(100n, 1100n, 0.5, 0.5);
    expect(Number(zoomed.endNs - zoomed.startNs)).toBe(500);
  });
});
