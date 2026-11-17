export interface FlamegraphNode {
  id: string;
  name: string;
  depth: number;
  parentId: string | null;
  samples: number;
  selfSamples: number;
  startPct: number;
  widthPct: number;
  percentage: number;
  timeMs: number;
  isHotspot: boolean;
  color: string;
}

export interface FlamegraphView {
  totalSamples: number;
  maxDepth: number;
  rows: FlamegraphNode[][];
  nodes: FlamegraphNode[];
  hotspot: FlamegraphNode | null;
}

interface TrieNode {
  id: string;
  name: string;
  depth: number;
  parentId: string | null;
  samples: number;
  selfSamples: number;
  children: Map<string, TrieNode>;
}

const SLATE_TONAL_STEPS = ['#1C2028', '#1E232C', '#222630', '#262B35', '#2A2F3A'] as const;

function insertStack(root: TrieNode, frames: readonly string[], count: number, counter: { next: number }): void {
  root.samples += count;
  let cursor = root;
  for (const frame of frames) {
    let child = cursor.children.get(frame);
    if (!child) {
      child = {
        id: `fg_${counter.next++}`,
        name: frame,
        depth: cursor.depth + 1,
        parentId: cursor.id,
        samples: 0,
        selfSamples: 0,
        children: new Map(),
      };
      cursor.children.set(frame, child);
    }
    child.samples += count;
    cursor = child;
  }
  cursor.selfSamples += count;
}

function buildTrie(text: string): TrieNode {
  const root: TrieNode = { id: 'fg_root', name: 'Total', depth: 0, parentId: null, samples: 0, selfSamples: 0, children: new Map() };
  const counter = { next: 1 };
  for (const rawLine of text.split(/\r?\n/)) {
    const trimmed = rawLine.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const spaceIdx = trimmed.lastIndexOf(' ');
    if (spaceIdx <= 0) continue;
    const count = Number.parseInt(trimmed.slice(spaceIdx + 1).trim(), 10);
    if (!Number.isFinite(count) || count <= 0) continue;
    const frames = trimmed.slice(0, spaceIdx).trim().split(';').map((f) => f.trim()).filter(Boolean);
    if (frames.length > 0) insertStack(root, frames, count, counter);
  }
  return root;
}

export function parseFoldedStacks(text: string, samplePeriodUs = 10): FlamegraphView {
  const root = buildTrie(text);
  if (root.samples === 0) {
    return { totalSamples: 0, maxDepth: 0, rows: [], nodes: [], hotspot: null };
  }

  const flatNodes: FlamegraphNode[] = [];
  let maxDepth = 0;

  function emit(node: TrieNode, startPct: number): void {
    const widthPct = (node.samples / root.samples) * 100;
    const toneIdx = (node.name.length + node.depth) % SLATE_TONAL_STEPS.length;
    flatNodes.push({
      id: node.id,
      name: node.name,
      depth: node.depth,
      parentId: node.parentId,
      samples: node.samples,
      selfSamples: node.selfSamples,
      startPct,
      widthPct,
      percentage: Math.round(widthPct * 10) / 10,
      timeMs: Math.round(((node.samples * samplePeriodUs) / 1000) * 100) / 100,
      isHotspot: false,
      color: SLATE_TONAL_STEPS[toneIdx] ?? '#1C2028',
    });
    if (node.depth > maxDepth) maxDepth = node.depth;
    const children = Array.from(node.children.values()).sort((a, b) => b.samples - a.samples);
    let offset = startPct;
    for (const child of children) {
      emit(child, offset);
      offset += (child.samples / root.samples) * 100;
    }
  }

  emit(root, 0);
  const hotspot = flatNodes
    .filter((n) => n.depth > 0 && n.selfSamples > 0)
    .sort((a, b) => b.selfSamples - a.selfSamples || b.samples - a.samples)[0] ?? null;
  if (hotspot) {
    hotspot.isHotspot = true;
    hotspot.color = '#2A2F3A';
  }

  const rows: FlamegraphNode[][] = Array.from({ length: maxDepth + 1 }, () => []);
  for (const node of flatNodes) rows[node.depth]?.push(node);

  return { totalSamples: root.samples, maxDepth, rows, nodes: flatNodes, hotspot };
}

export function toIcicleRows(view: FlamegraphView): FlamegraphNode[][] {
  return [...view.rows].reverse();
}

export function getTopHotspots(view: FlamegraphView, limit = 5): FlamegraphNode[] {
  return view.nodes
    .filter((n) => n.depth > 0 && n.selfSamples > 0)
    .sort((a, b) => b.selfSamples - a.selfSamples || b.samples - a.samples)
    .slice(0, Math.max(0, limit));
}
