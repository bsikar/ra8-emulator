import { Core } from 'ra8-rpc-client';
import {
  type ExecutionSlice,
  TIMELINE_AXIS_HEIGHT,
  TIMELINE_LABEL_WIDTH,
  TIMELINE_LANES,
  TIMELINE_RIGHT_PAD,
  type TimelineCoreFilter,
  type TimelineLaneId,
  computeWindowUtilization,
  formatTimelineNs,
  sliceLaneId,
} from './timeline-model';

export interface TimelineDrawOptions {
  coreFilter?: TimelineCoreFilter;
  threadFilter?: number;
  hoveredSlice?: ExecutionSlice | null;
}

function sliceMatchesFilters(
  slice: ExecutionSlice,
  coreFilter: TimelineCoreFilter,
  threadFilter: number
): boolean {
  if (coreFilter === 'cpu0' && slice.core !== Core.Cpu0) return false;
  if (coreFilter === 'cpu1' && slice.core !== Core.Cpu1) return false;
  if (threadFilter !== 0xffff_ffff && slice.kind === 'thread' && slice.thread !== threadFilter) {
    return false;
  }
  return true;
}

function drawAxisRuler(
  ctx: CanvasRenderingContext2D,
  windowStartNs: bigint,
  windowEndNs: bigint,
  labelW: number,
  chartW: number,
  cssW: number
): void {
  ctx.fillStyle = '#0B0E15';
  ctx.fillRect(0, 0, cssW, TIMELINE_AXIS_HEIGHT);
  ctx.strokeStyle = '#21242B';
  ctx.beginPath();
  ctx.moveTo(0, TIMELINE_AXIS_HEIGHT - 0.5);
  ctx.lineTo(cssW, TIMELINE_AXIS_HEIGHT - 0.5);
  ctx.stroke();

  ctx.font = '11px JetBrains Mono, monospace';
  ctx.fillStyle = '#989CA7';
  ctx.fillText('TIME AXIS', 10, 16);

  const ticks = 5;
  const span = Number(windowEndNs > windowStartNs ? windowEndNs - windowStartNs : 1n);
  ctx.fillStyle = '#80848D';
  for (let i = 0; i <= ticks; i++) {
    const ratio = i / ticks;
    const x = labelW + ratio * chartW;
    const ns = windowStartNs + BigInt(Math.round(span * ratio));
    const txt = formatTimelineNs(ns);
    const tx = i === ticks ? Math.max(labelW, x - ctx.measureText(txt).width) : x + 3;
    ctx.fillText(txt, tx, 15);
    ctx.strokeStyle = '#1F2229';
    ctx.beginPath();
    ctx.moveTo(Math.round(x) + 0.5, TIMELINE_AXIS_HEIGHT - 5);
    ctx.lineTo(Math.round(x) + 0.5, TIMELINE_AXIS_HEIGHT);
    ctx.stroke();
  }
}

function drawLaneBackgrounds(
  ctx: CanvasRenderingContext2D,
  laneH: number,
  cssW: number,
  labelW: number,
  coreFilter: TimelineCoreFilter,
  laneActivePct: Record<TimelineLaneId, number>
): void {
  ctx.font = '12px Inter, system-ui, sans-serif';
  for (let i = 0; i < TIMELINE_LANES.length; i++) {
    const lane = TIMELINE_LANES[i]!;
    const y = TIMELINE_AXIS_HEIGHT + i * laneH;
    const muted = (coreFilter === 'cpu0' && lane.core === Core.Cpu1) || (coreFilter === 'cpu1' && lane.core === Core.Cpu0);
    ctx.fillStyle = muted ? '#0E1117' : i % 2 === 0 ? '#10131A' : '#13161E';
    ctx.fillRect(0, y, cssW, laneH);
    ctx.strokeStyle = '#1F2229';
    ctx.beginPath();
    ctx.moveTo(0, Math.round(y + laneH) - 0.5);
    ctx.lineTo(cssW, Math.round(y + laneH) - 0.5);
    ctx.stroke();

    ctx.fillStyle = muted ? '#5A606D' : '#989CA7';
    ctx.fillText(lane.label, 10, y + Math.min(laneH - 6, laneH * 0.54));
    const pct = laneActivePct[lane.id];
    if (pct > 0) {
      ctx.fillStyle = '#80848D';
      ctx.fillText(`${pct}%`, labelW - 34, y + Math.min(laneH - 6, laneH * 0.54));
    }
  }
  ctx.strokeStyle = '#21242B';
  ctx.beginPath();
  ctx.moveTo(labelW - 0.5, 0);
  ctx.lineTo(labelW - 0.5, TIMELINE_AXIS_HEIGHT + laneH * TIMELINE_LANES.length);
  ctx.stroke();
}

function drawSlicesInLanes(
  ctx: CanvasRenderingContext2D,
  slices: readonly ExecutionSlice[],
  windowStartNs: bigint,
  windowEndNs: bigint,
  labelW: number,
  chartW: number,
  laneH: number,
  opts: TimelineDrawOptions
): void {
  const span = Number(windowEndNs > windowStartNs ? windowEndNs - windowStartNs : 1n);
  const laneIndex = new Map<TimelineLaneId, number>(TIMELINE_LANES.map((l, idx) => [l.id, idx]));
  const coreFilter = opts.coreFilter ?? 'both';
  const threadFilter = opts.threadFilter ?? 0xffff_ffff;

  for (const s of slices) {
    if (s.endNs < windowStartNs || s.startNs > windowEndNs) continue;
    const idx = laneIndex.get(sliceLaneId(s)) ?? 0;
    const laneTop = TIMELINE_AXIS_HEIGHT + idx * laneH;
    const x1 = labelW + (Math.max(0, Number(s.startNs - windowStartNs)) / span) * chartW;
    const x2 = labelW + (Math.min(span, Number(s.endNs - windowStartNs)) / span) * chartW;
    const w = Math.max(2, x2 - x1);
    const matches = sliceMatchesFilters(s, coreFilter, threadFilter);
    const barH = s.kind === 'idle' ? Math.max(6, laneH * 0.28) : Math.max(12, laneH - 10);
    const barY = s.kind === 'idle' ? laneTop + (laneH - barH) / 2 : laneTop + 5;
    const isHovered = opts.hoveredSlice === s;

    ctx.globalAlpha = matches ? 1 : 0.26;
    ctx.fillStyle = s.kind === 'isr' ? '#2A2F3A' : s.kind === 'idle' ? '#161920' : '#1C2028';
    ctx.fillRect(x1, barY, w, barH);
    ctx.strokeStyle = isHovered ? '#F2F5FC' : s.kind === 'isr' ? '#B8C4D9' : '#23262D';
    ctx.strokeRect(x1 + 0.5, barY + 0.5, Math.max(1, w - 1), Math.max(1, barH - 1));

    if (w >= 46 && s.kind !== 'idle') {
      ctx.save();
      ctx.beginPath();
      ctx.rect(x1 + 4, barY, w - 8, barH);
      ctx.clip();
      ctx.font = '12px JetBrains Mono, monospace';
      ctx.fillStyle = s.kind === 'isr' ? '#F2F5FC' : '#DCE0EC';
      ctx.fillText(s.label, x1 + 6, barY + barH * 0.66);
      ctx.restore();
    }
    ctx.globalAlpha = 1;
  }
}

function drawBrushOverlay(
  ctx: CanvasRenderingContext2D,
  brush: { fromNs: bigint; toNs: bigint } | null,
  windowStartNs: bigint,
  windowEndNs: bigint,
  labelW: number,
  chartW: number,
  cssH: number
): void {
  if (!brush || brush.toNs <= brush.fromNs) return;
  if (brush.toNs < windowStartNs || brush.fromNs > windowEndNs) return;
  const span = Number(windowEndNs > windowStartNs ? windowEndNs - windowStartNs : 1n);
  const bx1 = labelW + (Math.max(0, Number(brush.fromNs - windowStartNs)) / span) * chartW;
  const bx2 = labelW + (Math.min(span, Number(brush.toNs - windowStartNs)) / span) * chartW;
  const bw = Math.max(2, bx2 - bx1);

  ctx.fillStyle = 'rgba(184, 196, 217, 0.12)';
  ctx.fillRect(bx1, TIMELINE_AXIS_HEIGHT, bw, Math.max(12, cssH - TIMELINE_AXIS_HEIGHT));

  ctx.strokeStyle = '#B8C4D9';
  ctx.beginPath();
  ctx.moveTo(Math.round(bx1) + 0.5, 0);
  ctx.lineTo(Math.round(bx1) + 0.5, cssH);
  ctx.moveTo(Math.round(bx2) + 0.5, 0);
  ctx.lineTo(Math.round(bx2) + 0.5, cssH);
  ctx.stroke();

  ctx.font = '11px JetBrains Mono, monospace';
  ctx.fillStyle = '#F2F5FC';
  ctx.fillText('[A]', bx1 + 4, 15);
  if (bw > 44) ctx.fillText('[B]', Math.max(bx1 + 26, bx2 - 24), 15);
}

export function drawProfileTimeline(
  ctx: CanvasRenderingContext2D,
  slices: readonly ExecutionSlice[],
  windowStartNs: bigint,
  windowEndNs: bigint,
  brush: { fromNs: bigint; toNs: bigint } | null,
  cssW: number,
  cssH: number,
  dpr: number,
  opts: TimelineDrawOptions = {}
): void {
  ctx.save();
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.fillStyle = '#10131A';
  ctx.fillRect(0, 0, cssW, cssH);

  const labelW = Math.min(TIMELINE_LABEL_WIDTH, Math.max(88, Math.floor(cssW * 0.22)));
  const chartW = Math.max(10, cssW - labelW - TIMELINE_RIGHT_PAD);
  const laneH = Math.max(22, (cssH - TIMELINE_AXIS_HEIGHT) / TIMELINE_LANES.length);
  const util = computeWindowUtilization(slices, windowStartNs, windowEndNs);

  drawAxisRuler(ctx, windowStartNs, windowEndNs, labelW, chartW, cssW);
  drawLaneBackgrounds(ctx, laneH, cssW, labelW, opts.coreFilter ?? 'both', util.laneActivePct);
  drawSlicesInLanes(ctx, slices, windowStartNs, windowEndNs, labelW, chartW, laneH, opts);
  drawBrushOverlay(ctx, brush, windowStartNs, windowEndNs, labelW, chartW, cssH);
  ctx.restore();
}
