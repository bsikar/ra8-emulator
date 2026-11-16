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

const PALETTE = ['#1F4E78', '#255B6E', '#2B6257', '#53527A', '#694F62', '#325B84'];

export function parseFoldedStacks(text: string, samplePeriodUs = 10): FlamegraphView {
  const root: TrieNode = {
    id: 'fg_root',
    name: 'CPU0 Total',
    depth: 0,
    parentId: null,
    samples: 0,
    selfSamples: 0,
    children: new Map(),
  };

  let nextId = 1;
  for (const rawLine of text.split(/\r?\n/)) {
    const trimmed = rawLine.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const spaceIdx = trimmed.lastIndexOf(' ');
    if (spaceIdx <= 0) continue;

    const stackStr = trimmed.slice(0, spaceIdx).trim();
    const count = Number.parseInt(trimmed.slice(spaceIdx + 1).trim(), 10);
    if (!Number.isFinite(count) || count <= 0) continue;

    const frames = stackStr.split(';').map((f) => f.trim()).filter(Boolean);
    if (frames.length === 0) continue;

    root.samples += count;
    let cursor = root;
    for (let i = 0; i < frames.length; i++) {
      const frame = frames[i];
      let child = cursor.children.get(frame);
      if (!child) {
        child = {
          id: `fg_${nextId++}`,
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

  if (root.samples === 0) {
    return { totalSamples: 0, maxDepth: 0, rows: [], nodes: [], hotspot: null };
  }

  const flatNodes: FlamegraphNode[] = [];
  let maxDepth = 0;

  function emit(node: TrieNode, startPct: number): void {
    const widthPct = (node.samples / root.samples) * 100;
    const color = PALETTE[(node.name.length + node.depth) % PALETTE.length];
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
      color,
    });
    if (node.depth > maxDepth) maxDepth = node.depth;

    const children = Array.from(node.children.values()).sort((a, b) => b.samples - a.samples);
    let childOffset = startPct;
    for (const child of children) {
      emit(child, childOffset);
      childOffset += (child.samples / root.samples) * 100;
    }
  }

  emit(root, 0);

  const candidateLeaves = flatNodes.filter((n) => n.depth > 0 && n.selfSamples > 0);
  const hotspot =
    candidateLeaves.sort((a, b) => b.selfSamples - a.selfSamples || b.samples - a.samples)[0] ?? null;
  if (hotspot) {
    hotspot.isHotspot = true;
    hotspot.color = '#8A332D';
  }

  const rows: FlamegraphNode[][] = Array.from({ length: maxDepth + 1 }, () => []);
  for (const node of flatNodes) {
    rows[node.depth].push(node);
  }

  return {
    totalSamples: root.samples,
    maxDepth,
    rows,
    nodes: flatNodes,
    hotspot,
  };
}
