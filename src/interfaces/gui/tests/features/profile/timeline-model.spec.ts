import { Core, EventKind } from 'ra8-rpc-client';
import {
  TIMELINE_AXIS_HEIGHT,
  buildExecutionSlices,
  computeWindowUtilization,
  hitTestTimelineSlice,
  panTimelineWindow,
  sliceLaneId,
  timelineXToNs,
  timelineYToLane,
  zoomTimelineWindow,
} from '../../../src/app/features/profile/timeline-model';

describe('timeline-model', () => {
  it('builds nested ISR and RTOS task slices across 4 lanes and hit-tests coordinates', () => {
    const built = buildExecutionSlices(
      [
        { id: 1, core: Core.Cpu0, kind: EventKind.RtosSwitch, virtualNs: 100n, thread: 1, exception: 0, name: 'worker' },
        { id: 2, core: Core.Cpu0, kind: EventKind.IsrEnter, virtualNs: 300n, thread: 1, exception: 15, name: 'SysTick' },
        { id: 3, core: Core.Cpu0, kind: EventKind.IsrLeave, virtualNs: 450n, thread: 1, exception: 15, name: '' },
        { id: 4, core: Core.Cpu0, kind: EventKind.RtosIdle, virtualNs: 900n, thread: 0, exception: 0, name: 'IDLE' },
        { id: 5, core: Core.Cpu1, kind: EventKind.RtosSwitch, virtualNs: 200n, thread: 2, exception: 0, name: 'ipc' },
      ],
      1100n
    );

    expect(built.slices.filter((s) => s.core === Core.Cpu0).map((s) => `${s.kind}:${s.label}`)).toEqual([
      'thread:worker',
      'isr:SysTick',
      'thread:worker',
      'idle:IDLE',
    ]);
    expect(sliceLaneId(built.slices[0]!)).toBe('cpu0-threads');
    expect(sliceLaneId(built.slices[1]!)).toBe('cpu0-isrs');
    expect(built.utilization.cpu0ActivePct).toBe(80);

    const isrHit = hitTestTimelineSlice(built.slices, 100n, 1100n, 'cpu0-isrs', 250, 1000);
    expect(isrHit?.label).toBe('SysTick');
    expect(hitTestTimelineSlice(built.slices, 100n, 1100n, 'cpu0-threads', 250, 1000)).toBeNull();
    expect(hitTestTimelineSlice(built.slices, 100n, 1100n, Core.Cpu1, 500, 1000)?.label).toBe('ipc');
  });

  it('computes viewport utilization, cursor zoom, clamped pan, and pointer coordinate mapping', () => {
    const built = buildExecutionSlices(
      [
        { id: 1, core: Core.Cpu0, kind: EventKind.RtosSwitch, virtualNs: 0n, thread: 1, exception: 0, name: 'taskA' },
        { id: 2, core: Core.Cpu0, kind: EventKind.RtosIdle, virtualNs: 500n, thread: 0, exception: 0, name: 'IDLE' },
      ],
      1000n
    );

    const firstHalf = computeWindowUtilization(built.slices, 0n, 500n);
    expect(firstHalf.cpu0ActivePct).toBe(100);
    expect(firstHalf.laneActivePct['cpu0-threads']).toBe(100);

    const secondHalf = computeWindowUtilization(built.slices, 500n, 1000n);
    expect(secondHalf.cpu0ActivePct).toBe(0);

    const zoomed = zoomTimelineWindow(100n, 1100n, 0.5, 0.5);
    expect(Number(zoomed.endNs - zoomed.startNs)).toBe(500);
    expect(zoomed.startNs).toBe(350n);

    const pannedLeft = panTimelineWindow(200n, 700n, -500n, 0n, 1000n);
    expect(pannedLeft).toEqual({ startNs: 0n, endNs: 500n });

    const pannedRight = panTimelineWindow(200n, 700n, 800n, 0n, 1000n);
    expect(pannedRight).toEqual({ startNs: 500n, endNs: 1000n });

    expect(timelineXToNs(250, 1000, 0n, 1000n)).toBe(250n);
    expect(timelineYToLane(10, 200)).toBeNull();
    expect(timelineYToLane(TIMELINE_AXIS_HEIGHT + 5, 224)).toBe('cpu0-threads');
    expect(timelineYToLane(TIMELINE_AXIS_HEIGHT + 60, 224)).toBe('cpu0-isrs');
    expect(timelineYToLane(TIMELINE_AXIS_HEIGHT + 110, 224)).toBe('cpu1-threads');
    expect(timelineYToLane(TIMELINE_AXIS_HEIGHT + 160, 224)).toBe('cpu1-isrs');
  });
});
