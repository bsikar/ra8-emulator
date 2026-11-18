import { Core, EventKind } from 'ra8-rpc-client';
import type { TraceTimelineEntry } from '../../core/stores/profile.store';

export const MAX_TIMELINE_SLICES = 4096;
export const TIMELINE_AXIS_HEIGHT = 24;
export const TIMELINE_LABEL_WIDTH = 132;
export const TIMELINE_RIGHT_PAD = 12;

export type TimelineLaneId = 'cpu0-threads' | 'cpu0-isrs' | 'cpu1-threads' | 'cpu1-isrs';
export type TimelineCoreFilter = 'cpu0' | 'cpu1' | 'both';

export interface TimelineLaneSpec {
  id: TimelineLaneId;
  core: Core;
  kind: 'thread' | 'isr';
  label: string;
}

export const TIMELINE_LANES: readonly TimelineLaneSpec[] = [
  { id: 'cpu0-threads', core: Core.Cpu0, kind: 'thread', label: 'CPU0 · M85 Threads' },
  { id: 'cpu0-isrs', core: Core.Cpu0, kind: 'isr', label: 'CPU0 · M85 ISRs' },
  { id: 'cpu1-threads', core: Core.Cpu1, kind: 'thread', label: 'CPU1 · M33 Threads' },
  { id: 'cpu1-isrs', core: Core.Cpu1, kind: 'isr', label: 'CPU1 · M33 ISRs' },
];

export interface ExecutionSlice {
  core: Core;
  startNs: bigint;
  endNs: bigint;
  kind: 'isr' | 'thread' | 'idle';
  label: string;
  depth: number;
  exception: number;
  thread: number;
}

export interface TimelineUtilization {
  cpu0ActivePct: number;
  cpu1ActivePct: number;
  windowStartNs: bigint;
  windowEndNs: bigint;
}

export interface WindowUtilization extends TimelineUtilization {
  laneActivePct: Record<TimelineLaneId, number>;
}

export interface TimelineBuildResult {
  slices: ExecutionSlice[];
  utilization: TimelineUtilization;
}

interface CoreCursorState {
  activeStart: bigint;
  baseKind: 'thread' | 'idle';
  baseLabel: string;
  baseThread: number;
  isrStack: Array<{ exception: number; label: string }>;
}

function flushSlice(out: ExecutionSlice[], core: Core, st: CoreCursorState, endNs: bigint): void {
  if (endNs <= st.activeStart) return;
  const topIsr = st.isrStack[st.isrStack.length - 1];
  out.push({
    core,
    startNs: st.activeStart,
    endNs,
    kind: topIsr ? 'isr' : st.baseKind,
    label: topIsr ? topIsr.label : st.baseLabel,
    depth: st.isrStack.length,
    exception: topIsr?.exception ?? 0,
    thread: st.baseThread,
  });
  if (out.length > MAX_TIMELINE_SLICES) out.shift();
  st.activeStart = endNs;
}

function makeCursor(startNs: bigint): CoreCursorState {
  return {
    activeStart: startNs,
    baseKind: 'thread',
    baseLabel: 'Reset/Main',
    baseThread: 0,
    isrStack: [],
  };
}

function applyTraceEvent(
  out: ExecutionSlice[],
  stateMap: Map<Core, CoreCursorState>,
  evt: TraceTimelineEntry
): void {
  let st = stateMap.get(evt.core);
  if (!st) {
    st = makeCursor(evt.virtualNs);
    stateMap.set(evt.core, st);
  }
  flushSlice(out, evt.core, st, evt.virtualNs);
  if (evt.kind === EventKind.IsrEnter) {
    st.isrStack.push({
      exception: evt.exception,
      label: evt.name || `IRQ#${evt.exception}`,
    });
  } else if (evt.kind === EventKind.IsrLeave) {
    if (st.isrStack.length > 0) st.isrStack.pop();
  } else if (evt.kind === EventKind.RtosIdle) {
    st.baseKind = 'idle';
    st.baseLabel = 'IDLE';
    st.baseThread = evt.thread;
  } else if (evt.kind === EventKind.RtosSwitch) {
    st.baseKind = 'thread';
    st.baseLabel = evt.name || `Thread 0x${evt.thread.toString(16)}`;
    st.baseThread = evt.thread;
  }
}

export function sliceLaneId(slice: ExecutionSlice): TimelineLaneId {
  if (slice.core === Core.Cpu1) {
    return slice.kind === 'isr' ? 'cpu1-isrs' : 'cpu1-threads';
  }
  return slice.kind === 'isr' ? 'cpu0-isrs' : 'cpu0-threads';
}

export function computeWindowUtilization(
  slices: readonly ExecutionSlice[],
  viewStartNs: bigint,
  viewEndNs: bigint
): WindowUtilization {
  const laneActivePct: Record<TimelineLaneId, number> = {
    'cpu0-threads': 0,
    'cpu0-isrs': 0,
    'cpu1-threads': 0,
    'cpu1-isrs': 0,
  };
  const span = viewEndNs > viewStartNs ? Number(viewEndNs - viewStartNs) : 0;
  if (span <= 0) {
    return { cpu0ActivePct: 0, cpu1ActivePct: 0, windowStartNs: viewStartNs, windowEndNs: viewEndNs, laneActivePct };
  }

  let cpu0Busy = 0;
  let cpu1Busy = 0;
  const laneBusy: Record<TimelineLaneId, number> = { ...laneActivePct };

  for (const s of slices) {
    if (s.kind === 'idle') continue;
    const s0 = s.startNs > viewStartNs ? s.startNs : viewStartNs;
    const s1 = s.endNs < viewEndNs ? s.endNs : viewEndNs;
    if (s1 <= s0) continue;
    const dur = Number(s1 - s0);
    if (s.core === Core.Cpu1) cpu1Busy += dur;
    else cpu0Busy += dur;
    laneBusy[sliceLaneId(s)] += dur;
  }

  for (const lane of TIMELINE_LANES) {
    laneActivePct[lane.id] = Math.min(100, Math.round((laneBusy[lane.id] * 100) / span));
  }
  return {
    cpu0ActivePct: Math.min(100, Math.round((cpu0Busy * 100) / span)),
    cpu1ActivePct: Math.min(100, Math.round((cpu1Busy * 100) / span)),
    windowStartNs: viewStartNs,
    windowEndNs: viewEndNs,
    laneActivePct,
  };
}

export function buildExecutionSlices(
  events: readonly TraceTimelineEntry[],
  fallbackEndNs = 0n
): TimelineBuildResult {
  if (events.length === 0) {
    return {
      slices: [],
      utilization: { cpu0ActivePct: 0, cpu1ActivePct: 0, windowStartNs: 0n, windowEndNs: fallbackEndNs },
    };
  }
  const sorted = [...events].sort((a, b) => (a.virtualNs < b.virtualNs ? -1 : a.virtualNs > b.virtualNs ? 1 : a.id - b.id));
  const minNs = sorted[0]!.virtualNs;
  const maxEventNs = sorted[sorted.length - 1]!.virtualNs;
  const windowEndNs = fallbackEndNs > maxEventNs ? fallbackEndNs : maxEventNs + 1000n;

  const stateMap = new Map<Core, CoreCursorState>();
  const slices: ExecutionSlice[] = [];
  for (const evt of sorted) applyTraceEvent(slices, stateMap, evt);
  for (const [core, st] of stateMap.entries()) flushSlice(slices, core, st, windowEndNs);

  const util = computeWindowUtilization(slices, minNs, windowEndNs);
  return {
    slices,
    utilization: {
      cpu0ActivePct: util.cpu0ActivePct,
      cpu1ActivePct: util.cpu1ActivePct,
      windowStartNs: minNs,
      windowEndNs,
    },
  };
}

export function zoomTimelineWindow(
  startNs: bigint,
  endNs: bigint,
  factor: number,
  anchorRatio = 0.5,
  minBoundNs = 0n,
  maxBoundNs?: bigint
): { startNs: bigint; endNs: bigint } {
  const curSpan = Number(endNs > startNs ? endNs - startNs : 1000n);
  let nextSpan = Math.max(100, Math.round(curSpan * factor));
  const minB = minBoundNs < 0n ? 0n : minBoundNs;
  if (maxBoundNs !== undefined && maxBoundNs > minB) {
    const maxSpan = Number(maxBoundNs - minB);
    if (nextSpan >= maxSpan) return { startNs: minB, endNs: maxBoundNs };
  }
  const clampedAnchor = Math.min(1, Math.max(0, anchorRatio));
  const anchorNs = startNs + BigInt(Math.round(curSpan * clampedAnchor));
  let nextStart = anchorNs - BigInt(Math.round(nextSpan * clampedAnchor));
  if (nextStart < minB) nextStart = minB;
  const nextEnd = nextStart + BigInt(nextSpan);
  if (maxBoundNs !== undefined && nextEnd > maxBoundNs) {
    const clampedStart = maxBoundNs - BigInt(nextSpan);
    return { startNs: clampedStart < minB ? minB : clampedStart, endNs: maxBoundNs };
  }
  return { startNs: nextStart, endNs: nextEnd };
}

export function panTimelineWindow(
  startNs: bigint,
  endNs: bigint,
  deltaNs: bigint,
  minBoundNs = 0n,
  maxBoundNs?: bigint
): { startNs: bigint; endNs: bigint } {
  const rawSpan = endNs > startNs ? endNs - startNs : 100n;
  const minB = minBoundNs < 0n ? 0n : minBoundNs;
  let nextStart = startNs + deltaNs;
  if (nextStart < minB) nextStart = minB;
  if (maxBoundNs !== undefined && maxBoundNs > minB) {
    const totalBound = maxBoundNs - minB;
    if (rawSpan >= totalBound) return { startNs: minB, endNs: maxBoundNs };
    const maxStart = maxBoundNs - rawSpan;
    if (nextStart > maxStart) nextStart = maxStart;
  }
  return { startNs: nextStart, endNs: nextStart + rawSpan };
}

export function timelineXToNs(
  xCss: number,
  chartWidthCss: number,
  windowStartNs: bigint,
  windowEndNs: bigint
): bigint {
  if (chartWidthCss <= 0 || windowEndNs <= windowStartNs) return windowStartNs;
  const ratio = Math.min(1, Math.max(0, xCss / chartWidthCss));
  return windowStartNs + BigInt(Math.round(Number(windowEndNs - windowStartNs) * ratio));
}

export function timelineYToLane(yCss: number, cssH: number): TimelineLaneId | null {
  if (yCss < TIMELINE_AXIS_HEIGHT || cssH <= TIMELINE_AXIS_HEIGHT) return null;
  const laneH = (cssH - TIMELINE_AXIS_HEIGHT) / TIMELINE_LANES.length;
  const idx = Math.min(TIMELINE_LANES.length - 1, Math.max(0, Math.floor((yCss - TIMELINE_AXIS_HEIGHT) / laneH)));
  return TIMELINE_LANES[idx]?.id ?? null;
}

export function hitTestTimelineSlice(
  slices: readonly ExecutionSlice[],
  windowStartNs: bigint,
  windowEndNs: bigint,
  target: Core | TimelineLaneId,
  xCss: number,
  widthCss: number
): ExecutionSlice | null {
  if (widthCss <= 0 || windowEndNs <= windowStartNs) return null;
  const targetNs = timelineXToNs(xCss, widthCss, windowStartNs, windowEndNs);
  const byLane = typeof target === 'string';
  for (let i = slices.length - 1; i >= 0; i--) {
    const s = slices[i]!;
    const matchesTarget = byLane ? sliceLaneId(s) === target : s.core === target;
    if (matchesTarget && targetNs >= s.startNs && targetNs <= s.endNs) return s;
  }
  return null;
}

export function formatTimelineNs(ns: bigint): string {
  const abs = ns < 0n ? -ns : ns;
  if (abs < 1000n) return `${ns} ns`;
  if (abs < 1_000_000n) return `${(Number(ns) / 1000).toFixed(1)} us`;
  return `${(Number(ns) / 1_000_000).toFixed(2)} ms`;
}
