import type { RewindLayoutNode, RewindTreeLayout } from '../../shared/utils/rewind-layout';
import type { RewindBookmark } from './rewind-model';

export interface DagViewportTransform {
  scaleX: number;
  offsetX: number;
  offsetY: number;
}

export interface DagResolvedPins {
  pointANode: RewindLayoutNode | null;
  pointBNode: RewindLayoutNode | null;
}

const RULER_HEIGHT = 28;
const RIGHT_MARGIN = 36;

export function computeDagTransform(layout: RewindTreeLayout, cssWidth: number, cssHeight: number): DagViewportTransform {
  const safeW = Math.max(1, cssWidth);
  const availW = Math.max(120, safeW - RIGHT_MARGIN);
  const scaleX = layout.width > availW ? availW / layout.width : 1;
  const contentH = Math.max(1, layout.height);
  const availH = Math.max(80, cssHeight - RULER_HEIGHT);
  const offsetY = RULER_HEIGHT + Math.max(0, (availH - contentH) * 0.35);
  return { scaleX, offsetX: 0, offsetY };
}

export function resolveDagPins(
  layout: RewindTreeLayout,
  pointAId: string,
  pointBId: string
): DagResolvedPins {
  return {
    pointANode: matchPinNode(layout.nodes, pointAId, 'first'),
    pointBNode: matchPinNode(layout.nodes, pointBId, 'last'),
  };
}

function matchPinNode(
  nodes: readonly RewindLayoutNode[],
  spec: string,
  fallbackKind: 'first' | 'last'
): RewindLayoutNode | null {
  if (nodes.length === 0) return null;
  const clean = spec.trim();
  const exact = nodes.find((n) => n.id === clean);
  if (exact) return exact;

  const lower = clean.toLowerCase();
  if (lower === '0' || lower === 'start') {
    return nodes.find((n) => n.branch === 0 && n.round === 0) ?? nodes[0] ?? null;
  }
  if (lower === 'latest' || lower === 'cursor' || lower === 'end') {
    return nodes.find((n) => n.isCursor) ?? nodes[nodes.length - 1] ?? null;
  }
  const bmMatch = /^(?:bm|marker)[:\s]+(\S+)/i.exec(clean);
  if (bmMatch?.[1]) {
    const bmNode = nodes.find((n) => n.label === bmMatch[1]);
    if (bmNode) return bmNode;
  }
  const branchRound = /^(\d+):(\d+)/.exec(clean);
  if (branchRound?.[1] && branchRound?.[2]) {
    const br = Number.parseInt(branchRound[1], 10);
    const rd = Number.parseInt(branchRound[2], 10);
    const byBr = nodes.filter((n) => n.branch === br);
    const exactBr = byBr.find((n) => n.round === rd);
    if (exactBr) return exactBr;
    if (byBr.length > 0) {
      return byBr.reduce((best, cur) =>
        Math.abs(cur.round - rd) < Math.abs(best.round - rd) ? cur : best
      );
    }
  }
  return fallbackKind === 'first' ? (nodes[0] ?? null) : (nodes[nodes.length - 1] ?? null);
}

export function hitTestDagCanvasNode(
  layout: RewindTreeLayout,
  x: number,
  y: number,
  cssWidth?: number,
  cssHeight?: number
): RewindLayoutNode | null {
  const tf =
    cssWidth !== undefined && cssHeight !== undefined
      ? computeDagTransform(layout, cssWidth, cssHeight)
      : { scaleX: 1, offsetX: 0, offsetY: 0 };

  for (const node of layout.nodes) {
    const nx = node.x * tf.scaleX + tf.offsetX;
    const ny = node.y + tf.offsetY;
    const hitHalfW = Math.max(18, Math.min(48, (node.pillWidth * tf.scaleX) / 2));
    if (x >= nx - hitHalfW && x <= nx + hitHalfW && y >= ny - 18 && y <= ny + 18) {
      return node;
    }
  }
  return null;
}

function drawRulerAndGrid(
  ctx: CanvasRenderingContext2D,
  layout: RewindTreeLayout,
  cssWidth: number,
  cssHeight: number,
  tf: DagViewportTransform,
  pins: DagResolvedPins
): void {
  ctx.fillStyle = '#0B0E15';
  ctx.fillRect(0, 0, cssWidth, RULER_HEIGHT);
  ctx.strokeStyle = '#1F2229';
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(0, RULER_HEIGHT);
  ctx.lineTo(cssWidth, RULER_HEIGHT);
  ctx.stroke();

  const seenX = new Set<number>();
  ctx.font = '11px monospace';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  for (const node of layout.nodes) {
    const sx = Math.round(node.x * tf.scaleX + tf.offsetX);
    if (seenX.has(sx)) continue;
    seenX.add(sx);
    ctx.strokeStyle = '#181C24';
    ctx.beginPath();
    ctx.moveTo(sx, RULER_HEIGHT);
    ctx.lineTo(sx, cssHeight);
    ctx.stroke();
    ctx.fillStyle = '#80848D';
    ctx.fillText(`r${node.round}`, sx, 14);
  }

  drawPinGuide(ctx, pins.pointANode, 'A', tf, cssHeight, false);
  drawPinGuide(ctx, pins.pointBNode, 'B', tf, cssHeight, true);
}

function drawPinGuide(
  ctx: CanvasRenderingContext2D,
  node: RewindLayoutNode | null,
  tag: 'A' | 'B',
  tf: DagViewportTransform,
  cssHeight: number,
  primary: boolean
): void {
  if (!node) return;
  const sx = Math.round(node.x * tf.scaleX + tf.offsetX);
  ctx.save();
  ctx.setLineDash([3, 3]);
  ctx.strokeStyle = primary ? '#B8C4D9' : '#5A606D';
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(sx, RULER_HEIGHT);
  ctx.lineTo(sx, cssHeight);
  ctx.stroke();
  ctx.setLineDash([]);

  const badgeX = tag === 'A' ? sx - 24 : sx + 4;
  ctx.fillStyle = primary ? '#1C2028' : '#161920';
  ctx.strokeStyle = primary ? '#B8C4D9' : '#80848D';
  ctx.fillRect(badgeX, 4, 20, 18);
  ctx.strokeRect(badgeX, 4, 20, 18);
  ctx.fillStyle = primary ? '#F2F5FC' : '#DCE0EC';
  ctx.font = '600 11px monospace';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(tag, badgeX + 10, 13);
  ctx.restore();
}

function drawBranchLanes(
  ctx: CanvasRenderingContext2D,
  layout: RewindTreeLayout,
  cssWidth: number,
  tf: DagViewportTransform
): void {
  ctx.font = '11px monospace';
  ctx.textAlign = 'left';
  ctx.textBaseline = 'middle';
  for (const lane of layout.branchLanes) {
    const ly = Math.round(lane.y + tf.offsetY);
    ctx.strokeStyle = lane.isActive ? '#1F2530' : '#171B22';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(0, ly);
    ctx.lineTo(cssWidth, ly);
    ctx.stroke();
    ctx.fillStyle = lane.isActive ? '#DCE0EC' : '#80848D';
    ctx.fillText(`#${lane.branch}`, 10, ly);
  }
}

function drawDagEdges(
  ctx: CanvasRenderingContext2D,
  layout: RewindTreeLayout,
  tf: DagViewportTransform
): void {
  const byId = new Map(layout.nodes.map((n) => [n.id, n]));
  for (const edge of layout.edges) {
    const from = byId.get(edge.fromId);
    const to = byId.get(edge.toId);
    if (!from || !to) continue;
    const x1 = from.x * tf.scaleX + tf.offsetX;
    const y1 = from.y + tf.offsetY;
    const x2 = to.x * tf.scaleX + tf.offsetX;
    const y2 = to.y + tf.offsetY;
    const dx = Math.max(24, Math.abs(x2 - x1) * 0.5);

    ctx.save();
    ctx.lineWidth = edge.isActiveBranch ? 2 : 1.5;
    ctx.strokeStyle = edge.isActiveBranch ? '#B8C4D9' : '#323A48';
    if (edge.isForkEdge || !edge.isActiveBranch) ctx.setLineDash([4, 3]);
    ctx.beginPath();
    ctx.moveTo(x1, y1);
    ctx.bezierCurveTo(x1 + dx, y1, x2 - dx, y2, x2, y2);
    ctx.stroke();
    ctx.restore();
  }
}

function drawDiamond(ctx: CanvasRenderingContext2D, cx: number, cy: number, radius: number): void {
  ctx.beginPath();
  ctx.moveTo(cx, cy - radius);
  ctx.lineTo(cx + radius, cy);
  ctx.lineTo(cx, cy + radius);
  ctx.lineTo(cx - radius, cy);
  ctx.closePath();
  ctx.fill();
  ctx.stroke();
}

function drawDagNodes(
  ctx: CanvasRenderingContext2D,
  layout: RewindTreeLayout,
  tf: DagViewportTransform,
  pins: DagResolvedPins,
  bookmarks: readonly RewindBookmark[]
): void {
  const bmByNodeId = new Set(bookmarks.map((b) => `${b.branch}:${b.r.toString()}:cpu0:0:retired`));
  for (const node of layout.nodes) {
    const nx = node.x * tf.scaleX + tf.offsetX;
    const ny = node.y + tf.offsetY;
    const isPinA = pins.pointANode?.id === node.id;
    const isPinB = pins.pointBNode?.id === node.id;
    const isCheckpoint = node.round === 0 || node.isJunction || node.id.includes(':cp:');
    const radius = node.isCursor ? 8 : isCheckpoint ? 7 : 5;

    ctx.fillStyle = node.isCursor ? '#F2F5FC' : isPinA || isPinB ? '#222630' : '#161920';
    ctx.strokeStyle = isPinB || node.isCursor ? '#F2F5FC' : isPinA ? '#B8C4D9' : '#80848D';
    ctx.lineWidth = node.isCursor || isPinA || isPinB ? 2 : 1.5;
    drawDiamond(ctx, nx, ny, radius);

    if (bmByNodeId.has(node.id)) {
      ctx.fillStyle = '#1C2028';
      ctx.strokeStyle = '#80848D';
      ctx.lineWidth = 1;
      ctx.fillRect(nx - 24, ny - 26, 48, 14);
      ctx.strokeRect(nx - 24, ny - 26, 48, 14);
      ctx.fillStyle = '#DCE0EC';
      ctx.font = '10px monospace';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText(node.label.slice(0, 7), nx, ny - 19);
    }

    ctx.fillStyle = node.isCursor ? '#F2F5FC' : '#C8CDD8';
    ctx.font = '11px monospace';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'top';
    ctx.fillText(node.label, nx, ny + radius + 5);
  }
}

/** Renders the Editorial Slate time-travel branch DAG with diamond checkpoints and [A]/[B] pins. */
export function renderRewindDagCanvas(
  ctx: CanvasRenderingContext2D,
  layout: RewindTreeLayout,
  cssWidth: number,
  cssHeight: number,
  dpr: number,
  pointAId: string,
  pointBId: string,
  bookmarks: readonly RewindBookmark[] = []
): void {
  ctx.save();
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, cssWidth, cssHeight);
  ctx.fillStyle = '#10131A';
  ctx.fillRect(0, 0, cssWidth, cssHeight);

  const tf = computeDagTransform(layout, cssWidth, cssHeight);
  const pins = resolveDagPins(layout, pointAId, pointBId);

  drawRulerAndGrid(ctx, layout, cssWidth, cssHeight, tf, pins);
  drawBranchLanes(ctx, layout, cssWidth, tf);
  drawDagEdges(ctx, layout, tf);
  drawDagNodes(ctx, layout, tf, pins, bookmarks);
  ctx.restore();
}
