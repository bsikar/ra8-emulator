import type { BoardPreset } from 'ra8-rpc-client';
import {
  filterLaunchCommands,
  filterRecentWorkspaces,
  formatPresetArchSummary,
  formatRelativeTime,
  formatWorkspaceHeaderMeta,
  formatWorkspaceSubline,
  type LaunchCommandItem,
} from '../../../src/app/features/launch/launch-commands';
import type { RecentWorkspaceEntry } from '../../../src/app/core/stores/workspace.store';

describe('launch-commands helpers', () => {
  it('filters and groups inline Launch Command Mode sections cleanly', () => {
    const noop = () => undefined;
    const items: LaunchCommandItem[] = [
      {
        id: 'new-ws',
        group: 'SESSION & WORKSPACE COMMANDS',
        icon: 'new-workspace',
        label: 'Create New Workspace...',
        description: 'Select board profile',
        shortcut: 'Ctrl + Shift + N',
        keywords: ['create'],
        run: noop,
      },
      {
        id: 'composer',
        group: 'HARDWARE PROBES & BOARD COMPOSER',
        icon: 'board-composer',
        label: 'Compose Custom Target Board (.board)...',
        description: 'Multi-MCU topology',
        shortcut: 'Ctrl + B',
        keywords: ['board'],
        run: noop,
      },
      {
        id: 'ext',
        group: 'IDE & EXTENSIONS',
        icon: 'extensions',
        label: 'Manage Extensions...',
        description: 'Web Worker extensions',
        keywords: ['plugin'],
        run: noop,
      },
    ];

    expect(filterLaunchCommands(items, '').map((s) => s.group)).toEqual([
      'SESSION & WORKSPACE COMMANDS',
      'HARDWARE PROBES & BOARD COMPOSER',
      'IDE & EXTENSIONS',
    ]);

    const filtered = filterLaunchCommands(items, '>board');
    expect(filtered.length).toBe(2);
    expect(filtered.flatMap((s) => s.items).map((i) => i.id)).toEqual(['new-ws', 'composer']);
  });

  it('filters recent workspaces and formats metadata, sublines, and relative time', () => {
    const baseMs = Date.parse('2026-11-17T12:00:00.000Z');
    const items: RecentWorkspaceEntry[] = [
      {
        id: 'w1',
        name: 'RA8P1 Vision HMI',
        path: '~/work/ra8p1-vision-hmi',
        wsUrl: 'ws://127.0.0.1:4567',
        pinned: true,
        lastOpenedIso: '2026-11-17T11:52:00.000Z',
        targetModel: 'EK-RA8P1',
        archSummary: 'Cortex-M85 + M33 + Ethos-U55',
        modeLabel: 'Emulator',
        artifactSummary: 'ek_ra8p1.board',
        checkpointCount: 1842,
      },
      {
        id: 'w2',
        name: 'FPB-RA8E1 Bootloader',
        path: '~/work/boot_signed.elf',
        wsUrl: 'ws://127.0.0.1:4568',
        pinned: false,
        lastOpenedIso: '2026-11-16T10:00:00.000Z',
        targetModel: 'FPB-RA8E1',
        entryAddress: '0x02000400',
      },
    ];

    expect(filterRecentWorkspaces(items, 'ethos').map((w) => w.id)).toEqual(['w1']);
    expect(formatWorkspaceHeaderMeta(items[0]!)).toBe('EK-RA8P1 · Cortex-M85 + M33 + Ethos-U55 · Emulator');
    expect(formatWorkspaceSubline(items[0]!)).toBe('~/work/ra8p1-vision-hmi · ek_ra8p1.board · 1,842 checkpoints');
    expect(formatWorkspaceSubline(items[1]!)).toBe('~/work/boot_signed.elf · Entry 0x02000400');
    expect(formatRelativeTime('2026-11-17T11:52:00.000Z', baseMs)).toBe('8m ago');
    expect(formatRelativeTime('2026-11-16T12:00:00.000Z', baseMs)).toBe('Yesterday');

    const dummyPreset = {
      hasNpu: true,
      cores: [
        { id: 'cpu0', label: 'CPU0', arch: 'Cortex-M85', clockMhz: 1000, enabled: true },
        { id: 'cpu1', label: 'CPU1', arch: 'Cortex-M33', clockMhz: 250, enabled: true },
      ],
    } as unknown as BoardPreset;
    expect(formatPresetArchSummary(dummyPreset)).toBe('Cortex-M85 + M33 + Ethos-U55');
  });
});
