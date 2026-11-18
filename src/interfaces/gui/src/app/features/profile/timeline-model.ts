import { Core, EventKind } from 'ra8-rpc-client';
import type { TraceTimelineEntry } from '../../core/stores/profile.store';

export const MAX_TIMELINE_SLICES = 4096;

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

function flushSlice(
  out: ExecutionSlice[],
  core: Core,
  st: CoreCursorState,
  endNs: bigint
): void {
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

  const span = Number(windowEndNs - minNs);
  let cpu0Busy = 0;
  let cpu1Busy = 0;
  for (const s of slices) {
    if (s.kind === 'idle') continue;
    const dur = Number(s.endNs - s.startNs);
    if (s.core === Core.Cpu1) cpu1Busy += dur;
    else cpu0Busy += dur;
  }
  return {
    slices,
    utilization: {
      cpu0ActivePct: span > 0 ? Math.min(100, Math.round((cpu0Busy * 100) / span)) : 0,
      cpu1ActivePct: span > 0 ? Math.min(100, Math.round((cpu1Busy * 100) / span)) : 0,
      windowStartNs: minNs,
      windowEndNs,
    },
  };
}

export function zoomTimelineWindow(
  startNs: bigint,
  endNs: bigint,
  factor: number,
  anchorRatio = 0.5
): { startNs: bigint; endNs: bigint } {
  const curSpan = Number(endNs > startNs ? endNs - startNs : 1000n);
  const nextSpan = Math.max(100, Math.round(curSpan * factor));
  const clampedAnchor = Math.min(1, Math.max(0, anchorRatio));
  const anchorNs = startNs + BigInt(Math.round(curSpan * clampedAnchor));
  const nextStart = anchorNs - BigInt(Math.round(nextSpan * clampedAnchor));
  const safeStart = nextStart < 0n ? 0n : nextStart;
  return { startNs: safeStart, endNs: safeStart + BigInt(nextSpan) };
}

export function hitTestTimelineSlice(
  slices: readonly ExecutionSlice[],
  windowStartNs: bigint,
  windowEndNs: bigint,
  core: Core,
  xCss: number,
  widthCss: number
): ExecutionSlice | null {
  if (widthCss <= 0 || windowEndNs <= windowStartNs) return null;
  const ratio = Math.min(1, Math.max(0, xCss / widthCss));
  const targetNs = windowStartNs + BigInt(Math.round(Number(windowEndNs - windowStartNs) * ratio));
  for (let i = slices.length - 1; i >= 0; i--) {
    const s = slices[i]!;
    if (s.core === core && targetNs >= s.startNs && targetNs <= s.endNs) return s;
  }
  return null;
}

export function drawProfileTimeline(
  ctx: CanvasRenderingContext2D,
  slices: readonly ExecutionSlice[],
  windowStartNs: bigint,
  windowEndNs: bigint,
  brush: { fromNs: bigint; toNs: bigint } | null,
  cssW: number,
  cssH: number,
  dpr: number
): void {
  ctx.save();
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.fillStyle = '#10131A';
  ctx.fillRect(0, 0, cssW, cssH);

  const span = Number(windowEndNs > windowStartNs ? windowEndNs - windowStartNs : 1n);
  const labelW = 88;
  const chartW = Math.max(10, cssW - labelW - 12);
  ctx.font = '12px monospace';
  ctx.fillStyle = '#94A3B8';
  ctx.fillText('CPU0 · M85', 8, 42);
  ctx.fillText('CPU1 · M33', 8, 92);

  for (const s of slices) {
    if (s.endNs < windowStartNs || s.startNs > windowEndNs) continue;
    const x1 = labelW + (Math.max(0, Number(s.startNs - windowStartNs)) / span) * chartW;
    const x2 = labelW + (Math.min(span, Number(s.endNs - windowStartNs)) / span) * chartW;
    const laneY = s.core === Core.Cpu1 ? 74 : 24;
    const h = s.kind === 'idle' ? 8 : s.kind === 'isr' ? 30 : 22;
    ctx.fillStyle = s.kind === 'isr' ? '#E2E8F0' : s.kind === 'idle' ? '#1E232C' : '#334155';
    ctx.fillRect(x1, laneY, Math.max(2, x2 - x1), h);
  }

  if (brush && brush.toNs > brush.fromNs) {
    const bx1 = labelW + (Math.max(0, Number(brush.fromNs - windowStartNs)) / span) * chartW;
    const bx2 = labelW + (Math.min(span, Number(brush.toNs - windowStartNs)) / span) * chartW;
    ctx.fillStyle = 'rgba(226, 232, 240, 0.14)';
    ctx.strokeStyle = '#94A3B8';
    ctx.fillRect(bx1, 12, Math.max(2, bx2 - bx1), Math.max(24, cssH - 24));
    ctx.strokeRect(bx1, 12, Math.max(2, bx2 - bx1), Math.max(24, cssH - 24));
  }
  ctx.restore();
}
