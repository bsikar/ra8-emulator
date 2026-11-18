import type { BundlePreview } from 'ra8-rpc-client';

export interface RecentBundleEntry {
  id: string;
  name: string;
  path: string;
  sizeBytes: number;
  compressed: boolean;
  board: string;
  elfSummary: string;
  hasSaveState: boolean;
  recording: boolean;
  entryCount: number;
  importedIso: string;
}

export interface BundleSummaryRow {
  label: string;
  value: string;
}

/** Format byte size into human-readable MB / KB / B units. */
export function formatByteSize(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B';
  if (bytes >= 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  if (bytes >= 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${Math.round(bytes)} B`;
}

/** Convert a parsed USTAR/Gzip `BundlePreview` into bundle manifest inspection rows. */
export function buildBundleSummaryRows(preview: BundlePreview, fileSizeBytes: number): BundleSummaryRow[] {
  const m = preview.manifest;
  const hasSnap = preview.entries.some((e) => e.path.endsWith('.ra8snap'));
  const formatKind = preview.compressed ? 'Gzip USTAR .tar.gz' : 'USTAR .tar';
  const modeVal = m?.recording
    ? hasSnap
      ? `Full Recording + Save State (${formatByteSize(fileSizeBytes)} ${formatKind})`
      : `Recording History (${formatByteSize(fileSizeBytes)} ${formatKind})`
    : hasSnap
      ? `Save State Snapshot Only (${formatByteSize(fileSizeBytes)} ${formatKind})`
      : `Session Archive (${formatByteSize(fileSizeBytes)} ${formatKind})`;

  const elfParts: string[] = [];
  if (m?.board) elfParts.push(m.board);
  if (m?.elf0) elfParts.push(`${m.elf0.name} (${formatByteSize(m.elf0.size)})`);
  if (m?.elf1) elfParts.push(`${m.elf1.name} (${formatByteSize(m.elf1.size)})`);
  const boardVal = elfParts.length > 0 ? elfParts.join(' · ') : `${preview.entries.length} archive entries`;

  const snapEntry = preview.entries.find((e) => e.path.endsWith('.ra8snap'));
  const stateVal = snapEntry ? `${snapEntry.path} (${formatByteSize(snapEntry.size)})` : 'None embedded (boot fresh at reset)';

  const spanVal = m
    ? `${m.recording ? '64-round checkpoints active' : 'Recording off'} · ${preview.entries.length} USTAR entries · Snapshot v${m.snapshotVersion}`
    : `${preview.entries.length} USTAR entries`;

  return [
    { label: 'Bundle Mode', value: modeVal },
    { label: 'Board & Images', value: boardVal },
    { label: 'Save State', value: stateVal },
    { label: 'Recording Span', value: spanVal },
  ];
}
