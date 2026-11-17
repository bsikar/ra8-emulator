import type { BoardPreset } from 'ra8-rpc-client';
import type { RecentWorkspaceEntry } from '../../core/stores/workspace.store';

export type LaunchCommandGroup =
  | 'SESSION & WORKSPACE COMMANDS'
  | 'HARDWARE PROBES & BOARD COMPOSER'
  | 'IDE & EXTENSIONS';

export type LaunchIconName =
  | 'search'
  | 'open-folder'
  | 'connect-remote'
  | 'import-archive'
  | 'new-workspace'
  | 'device-monitor'
  | 'board-composer'
  | 'settings'
  | 'pin'
  | 'kebab'
  | 'search-everywhere'
  | 'extensions'
  | 'vim'
  | 'palette';

export interface LaunchCommandItem {
  id: string;
  group: LaunchCommandGroup;
  icon: LaunchIconName;
  label: string;
  description: string;
  shortcut?: string;
  keywords: readonly string[];
  run: () => void | Promise<unknown>;
}

export interface LaunchCommandSection {
  group: LaunchCommandGroup;
  items: LaunchCommandItem[];
}

const GROUP_ORDER: readonly LaunchCommandGroup[] = [
  'SESSION & WORKSPACE COMMANDS',
  'HARDWARE PROBES & BOARD COMPOSER',
  'IDE & EXTENSIONS',
];

/** Filter and group inline Launch Command Mode items by query string. */
export function filterLaunchCommands(
  items: readonly LaunchCommandItem[],
  rawQuery: string
): LaunchCommandSection[] {
  const needle = rawQuery.trim().replace(/^>+/, '').trim().toLowerCase();
  const matched = needle
    ? items.filter((item) => {
        const hay = `${item.label} ${item.description} ${item.keywords.join(' ')}`.toLowerCase();
        return hay.includes(needle);
      })
    : items;

  const sections: LaunchCommandSection[] = [];
  for (const group of GROUP_ORDER) {
    const groupItems = matched.filter((item) => item.group === group);
    if (groupItems.length > 0) {
      sections.push({ group, items: groupItems });
    }
  }
  return sections;
}

/** Filter recent workspaces by name, path, target model, mode, artifact, or endpoint. */
export function filterRecentWorkspaces(
  items: readonly RecentWorkspaceEntry[],
  rawQuery: string
): RecentWorkspaceEntry[] {
  const needle = rawQuery.trim().toLowerCase();
  if (!needle) return [...items];
  return items.filter((entry) => {
    const hay = [
      entry.name,
      entry.path,
      entry.wsUrl,
      entry.targetModel ?? '',
      entry.archSummary ?? '',
      entry.modeLabel ?? '',
      entry.artifactSummary ?? '',
      entry.entryAddress ?? '',
    ]
      .join(' ')
      .toLowerCase();
    return hay.includes(needle);
  });
}

/** Format an ISO timestamp as a quiet relative age label (`8m ago`, `2h ago`, `Yesterday`). */
export function formatRelativeTime(iso: string, nowMs = Date.now()): string {
  const parsed = Date.parse(iso);
  if (!Number.isFinite(parsed)) return '—';
  const diffSec = Math.max(0, Math.floor((nowMs - parsed) / 1000));
  if (diffSec < 60) return 'Just now';
  const diffMin = Math.floor(diffSec / 60);
  if (diffMin < 60) return `${diffMin}m ago`;
  const diffHours = Math.floor(diffMin / 60);
  if (diffHours < 24) return `${diffHours}h ago`;
  const diffDays = Math.floor(diffHours / 24);
  if (diffDays === 1) return 'Yesterday';
  if (diffDays < 30) return `${diffDays}d ago`;
  return new Date(parsed).toISOString().slice(0, 10);
}

/** Build the middle-dot inline descriptor shown beside the workspace title. */
export function formatWorkspaceHeaderMeta(entry: RecentWorkspaceEntry): string {
  const parts = [entry.targetModel, entry.archSummary, entry.modeLabel]
    .map((p) => p?.trim() ?? '')
    .filter((p) => p.length > 0);
  return parts.join(' · ');
}

/** Build the JetBrains Mono technical subline beneath a workspace entry. */
export function formatWorkspaceSubline(entry: RecentWorkspaceEntry): string {
  const parts: string[] = [];
  if (entry.path.trim()) parts.push(entry.path.trim());
  if (entry.artifactSummary?.trim()) parts.push(entry.artifactSummary.trim());
  if (entry.checkpointCount !== undefined && entry.checkpointCount > 0) {
    parts.push(`${entry.checkpointCount.toLocaleString('en-US')} checkpoints`);
  }
  if (entry.entryAddress?.trim()) parts.push(`Entry ${entry.entryAddress.trim()}`);
  if (parts.length === 0) parts.push(entry.wsUrl);
  return parts.join(' · ');
}

export interface LaunchCommandHandlers {
  commandChordLabel: string;
  createWorkspace: () => void;
  openWorkspace: () => void;
  importArchive: () => void;
  connectRemote: () => void;
  openMonitor: () => void;
  openBoardComposer: () => void;
  openSettings: () => void;
  openPalette: () => void;
  openSearchEverywhere?: () => void;
  openExtensions?: () => void;
  toggleVim?: () => void;
}

function buildSessionCommands(handlers: LaunchCommandHandlers): LaunchCommandItem[] {
  return [
    {
      id: 'new-workspace',
      group: 'SESSION & WORKSPACE COMMANDS',
      icon: 'new-workspace',
      label: 'Create New Workspace...',
      description: 'Select board profile, execution target, and project source',
      shortcut: 'Ctrl + Shift + N',
      keywords: ['create', 'new', 'board', 'target'],
      run: handlers.createWorkspace,
    },
    {
      id: 'open-workspace',
      group: 'SESSION & WORKSPACE COMMANDS',
      icon: 'open-folder',
      label: 'Open Folder, .elf, or .board...',
      description: 'Browse local firmware image or board profile',
      shortcut: 'Ctrl + O',
      keywords: ['open', 'elf', 'board', 'folder', 'file'],
      run: handlers.openWorkspace,
    },
    {
      id: 'import-archive',
      group: 'SESSION & WORKSPACE COMMANDS',
      icon: 'import-archive',
      label: 'Import Session Bundle (.tar)...',
      description: 'Restore state.ra8snap and recorded checkpoint tree',
      shortcut: 'Ctrl + I',
      keywords: ['import', 'archive', 'tar', 'bundle', 'rewind'],
      run: handlers.importArchive,
    },
    {
      id: 'connect-remote',
      group: 'SESSION & WORKSPACE COMMANDS',
      icon: 'connect-remote',
      label: 'Connect to Remote Host or Live Session...',
      description: 'Attach via WebSocket RPC or observe CI / HIL',
      shortcut: 'Ctrl + R',
      keywords: ['connect', 'remote', 'ws', 'websocket', 'ssh'],
      run: handlers.connectRemote,
    },
  ];
}

function buildHardwareCommands(handlers: LaunchCommandHandlers): LaunchCommandItem[] {
  return [
    {
      id: 'device-monitor',
      group: 'HARDWARE PROBES & BOARD COMPOSER',
      icon: 'device-monitor',
      label: 'Attach Device Monitor (Serial / SWO)...',
      description: 'Inspect UART stream, channel routing, and SWO telemetry',
      shortcut: 'Ctrl + M',
      keywords: ['console', 'uart', 'serial', 'swo', 'monitor'],
      run: handlers.openMonitor,
    },
    {
      id: 'board-composer',
      group: 'HARDWARE PROBES & BOARD COMPOSER',
      icon: 'board-composer',
      label: 'Compose Custom Target Board (.board)...',
      description: 'Multi-MCU topology, external memory timing, and pin mapping',
      shortcut: 'Ctrl + B',
      keywords: ['hardware', 'board', 'composer', 'hil', 'peripherals'],
      run: handlers.openBoardComposer,
    },
    {
      id: 'probe-settings',
      group: 'HARDWARE PROBES & BOARD COMPOSER',
      icon: 'settings',
      label: 'Hardware Probe & Serial Port Settings...',
      description: 'Manage persistent USB Serial / VID:PID bindings and RPC endpoint',
      shortcut: 'Ctrl + ,',
      keywords: ['settings', 'probe', 'serial', 'preferences'],
      run: handlers.openSettings,
    },
  ];
}

function buildIdeCommands(handlers: LaunchCommandHandlers): LaunchCommandItem[] {
  const items: LaunchCommandItem[] = [];
  if (handlers.openSearchEverywhere) {
    items.push({
      id: 'search-everywhere',
      group: 'IDE & EXTENSIONS',
      icon: 'search-everywhere',
      label: 'Search Everywhere...',
      description: 'Find files, symbols, registers, addresses, and actions',
      shortcut: 'Shift + Shift',
      keywords: ['search', 'everywhere', 'symbols', 'files'],
      run: handlers.openSearchEverywhere,
    });
  }
  if (handlers.openExtensions) {
    items.push({
      id: 'extensions-sheet',
      group: 'IDE & EXTENSIONS',
      icon: 'extensions',
      label: 'Manage Extensions...',
      description: 'Install, enable, disable, or run Web Worker extensions',
      shortcut: 'Ctrl + Shift + X',
      keywords: ['extensions', 'worker', 'plugins'],
      run: handlers.openExtensions,
    });
  }
  if (handlers.toggleVim) {
    items.push({
      id: 'toggle-vim',
      group: 'IDE & EXTENSIONS',
      icon: 'vim',
      label: 'Toggle Vim Keybindings...',
      description: 'Switch modal Vim navigation and :ex prompt on or off',
      shortcut: ':vim',
      keywords: ['vim', 'modal', 'ex', 'navigation'],
      run: handlers.toggleVim,
    });
  }
  items.push({
    id: 'global-palette',
    group: 'IDE & EXTENSIONS',
    icon: 'palette',
    label: 'Open Global Command Palette...',
    description: 'Run execution, navigation, and session actions anywhere',
    shortcut: handlers.commandChordLabel.replace(/\+/g, ' + '),
    keywords: ['palette', 'command', 'actions'],
    run: handlers.openPalette,
  });
  return items;
}

/** Construct the grouped Launch Command Mode actions (`>`). */
export function buildLaunchCommands(handlers: LaunchCommandHandlers): LaunchCommandItem[] {
  return [
    ...buildSessionCommands(handlers),
    ...buildHardwareCommands(handlers),
    ...buildIdeCommands(handlers),
  ];
}

/** Build a concise core/NPU summary string from an official board preset. */
export function formatPresetArchSummary(preset: BoardPreset): string {
  const hasM85 = preset.cores.some((c) => c.arch === 'Cortex-M85');
  const hasM33 = preset.cores.some((c) => c.arch === 'Cortex-M33');
  if (hasM85 && hasM33) {
    return preset.hasNpu ? 'Cortex-M85 + M33 + Ethos-U55' : 'Cortex-M85 + Cortex-M33';
  }
  const primary = preset.cores[0];
  if (!primary) return 'ARM Cortex-M';
  return `${primary.arch} (${primary.clockMhz} MHz)`;
}
