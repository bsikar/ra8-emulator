import type { ContributedCommandEntry } from '../core/extensions/extension-storage';
import type { RecentElfEntry } from '../core/stores/recent-elf-db';
import type { CommandAction } from './command-mode.store';

export interface ShellCommandDeps {
  navigateByUrl: (url: string) => unknown;
  reloadActiveElf: () => unknown;
  openRecentElf: (entry: RecentElfEntry) => unknown;
  toggleFullScreen: () => unknown;
  openSearchEverywhere: () => unknown;
  openExtensions: () => unknown;
  toggleVim: () => unknown;
  toggleRunPause: () => unknown;
  stepOver: () => unknown;
  stepInto: () => unknown;
  openSettings: () => unknown;
  openHelp: () => unknown;
  disconnectSession: () => unknown;
  executeExtensionCommand: (command: string) => unknown;
}

/** Build the complete topbar, shortcut, recent-ELF, and extension command list. */
export function buildShellCommandActions(
  deps: ShellCommandDeps,
  recentElfs: readonly RecentElfEntry[],
  extCmds: readonly ContributedCommandEntry[]
): CommandAction[] {
  const base: CommandAction[] = [
    { id: 'nav-launch', label: 'Go to Launch', category: 'navigation', menu: 'view', shortcut: { key: '1' }, run: () => deps.navigateByUrl('/launch') },
    { id: 'nav-new-ws', label: 'New Workspace...', category: 'session', menu: 'file', shortcut: { mod: true, shift: true, key: 'n' }, run: () => deps.navigateByUrl('/workspace/new') },
    { id: 'nav-open', label: 'Open ELF or Workspace...', category: 'session', menu: 'file', shortcut: { mod: true, key: 'o' }, run: () => deps.navigateByUrl('/open') },
    { id: 'reload-elf', label: 'Reload ELF', category: 'session', menu: 'file', shortcut: { mod: true, key: 'r' }, isEnabled: (c) => c.canReload, run: () => deps.reloadActiveElf() },
    { id: 'nav-import', label: 'Import Session Bundle (.tar)...', category: 'session', menu: 'file', shortcut: { mod: true, key: 'i' }, run: () => deps.navigateByUrl('/import') },
    { id: 'nav-connect', label: 'Connect Remote Host...', category: 'session', menu: 'file', shortcut: { mod: true, shift: true, key: 'r' }, run: () => deps.navigateByUrl('/connect') },
    { id: 'nav-debug', label: 'Go to Debug', category: 'navigation', menu: 'view', shortcut: { key: '2' }, run: () => deps.navigateByUrl('/debug') },
    { id: 'nav-hw', label: 'Go to Hardware', category: 'navigation', menu: 'view', shortcut: { key: '3' }, run: () => deps.navigateByUrl('/hardware') },
    { id: 'nav-rewind', label: 'Go to Rewind', category: 'navigation', menu: 'view', shortcut: { key: '4' }, run: () => deps.navigateByUrl('/rewind') },
    { id: 'nav-profile', label: 'Go to Profile', category: 'navigation', menu: 'view', shortcut: { key: '5' }, run: () => deps.navigateByUrl('/profile') },
    { id: 'nav-console', label: 'Go to Console', category: 'navigation', menu: 'terminal', shortcut: { key: '6' }, run: () => deps.navigateByUrl('/console') },
    { id: 'nav-fullscreen', label: 'Full Screen', category: 'navigation', menu: 'view', shortcut: { key: 'F11' }, run: () => deps.toggleFullScreen() },
    { id: 'open-search', label: 'Search Everywhere', category: 'navigation', menu: 'view', run: () => deps.openSearchEverywhere() },
    { id: 'open-extensions', label: 'Extensions', category: 'extensions', menu: 'view', shortcut: { mod: true, shift: true, key: 'x' }, run: () => deps.openExtensions() },
    { id: 'toggle-vim', label: 'Toggle Vim Keybindings', category: 'session', menu: 'edit', run: () => deps.toggleVim() },
    { id: 'exec-run', label: 'Continue / Pause', category: 'execution', menu: 'file', shortcut: { key: 'F5' }, isEnabled: (c) => c.connected, run: () => deps.toggleRunPause() },
    { id: 'exec-over', label: 'Step Over', category: 'execution', menu: 'edit', shortcut: { key: 'F10' }, isEnabled: (c) => c.connected && !c.running, run: () => deps.stepOver() },
    { id: 'exec-into', label: 'Step Into', category: 'execution', menu: 'edit', shortcut: { shift: true, key: 'F11' }, isEnabled: (c) => c.connected && !c.running, run: () => deps.stepInto() },
    { id: 'open-settings', label: 'Session Settings', category: 'session', menu: 'file', shortcut: { mod: true, key: ',' }, run: () => deps.openSettings() },
    { id: 'open-help', label: 'Keyboard & Transport Help', category: 'help', menu: 'help', run: () => deps.openHelp() },
    { id: 'disconnect', label: 'Disconnect Session', category: 'session', menu: 'file', isEnabled: (c) => c.connected, run: () => deps.disconnectSession() },
  ];

  const recentActions: CommandAction[] = recentElfs.map((entry, idx) => ({
    id: `recent-elf:${idx}`,
    label: `Open Recent: ${entry.fileName}`,
    category: 'file',
    run: () => deps.openRecentElf(entry),
  }));

  const dynamic: CommandAction[] = extCmds.map((c) => ({
    id: `ext:${c.extensionId}:${c.command}`,
    label: `${c.extensionName}: ${c.title}`,
    category: 'extensions',
    run: () => deps.executeExtensionCommand(c.command),
  }));

  return [...base, ...recentActions, ...dynamic];
}
