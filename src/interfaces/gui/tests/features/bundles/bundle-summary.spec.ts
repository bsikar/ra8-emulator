import { describe, expect, it } from 'vitest';
import type { BundlePreview } from 'ra8-rpc-client';
import { buildBundleSummaryRows, formatByteSize } from '../../../src/app/features/bundles/bundle-summary';

describe('bundle-summary helpers', () => {
  it('formats byte sizes cleanly across B, KB, and MB ranges', () => {
    expect(formatByteSize(0)).toBe('0 B');
    expect(formatByteSize(512)).toBe('512 B');
    expect(formatByteSize(14 * 1024)).toBe('14.0 KB');
    expect(formatByteSize(3 * 1024 * 1024)).toBe('3.0 MB');
  });

  it('builds structured bundle inspection rows for recording + snapshot archives', () => {
    const preview: BundlePreview = {
      compressed: true,
      totalTarBytes: 65536,
      entries: [
        { path: 'manifest.json', size: 220, dataOffset: 512 },
        { path: 'state.ra8snap', size: 16384, dataOffset: 1024 },
      ],
      manifest: {
        format: 'ra8-session-bundle',
        version: 1,
        snapshotVersion: 2,
        board: 'ek_ra8d2',
        elf0: { name: 'cpu0.elf', identity: '4a91c08e', size: 842 * 1024 },
        elf1: { name: 'cpu1.elf', identity: '7f12b001', size: 196 * 1024 },
        recording: true,
      },
    };
    const rows = buildBundleSummaryRows(preview, 240_000);
    expect(rows.length).toBe(4);
    expect(rows[0]?.value).toContain('Full Recording + Save State');
    expect(rows[1]?.value).toContain('ek_ra8d2 · cpu0.elf (842.0 KB) · cpu1.elf (196.0 KB)');
    expect(rows[2]?.value).toContain('state.ra8snap');
    expect(rows[3]?.value).toContain('2 USTAR entries');
  });
});
