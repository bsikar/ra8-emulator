import { Core } from 'ra8-rpc-client';
import { describe, expect, it } from 'vitest';
import type { RecentElfEntry } from '../../src/app/core/stores/recent-elf-db';
import { CommandModeStore } from '../../src/app/shell/command-mode.store';
import { buildShellCommandActions } from '../../src/app/shell/shell-commands';

describe('buildShellCommandActions', () => {
  it('binds Reload ELF to Ctrl/Cmd+R, enables it via canReload context, and lists recent ELFs', () => {
    let reloaded = 0;
    let openedRecent = '';
    const recent: RecentElfEntry = {
      id: 'ws:0:ws://127.0.0.1:4567:app.elf',
      fileName: 'app.elf',
      core: Core.Cpu0,
      sourceKind: 'workspace',
      workspacePath: 'app.elf',
      handle: null,
      cachedBytes: new Uint8Array([1]),
      wsUrl: 'ws://127.0.0.1:4567',
      openedAtIso: '2026-11-21T12:00:00.000Z',
    };

    const actions = buildShellCommandActions(
      {
        navigateByUrl: () => undefined,
        reloadActiveElf: () => {
          reloaded += 1;
        },
        openRecentElf: (entry) => {
          openedRecent = entry.fileName;
        },
        toggleFullScreen: () => undefined,
        openSearchEverywhere: () => undefined,
        openExtensions: () => undefined,
        toggleVim: () => undefined,
        toggleRunPause: () => undefined,
        stepOver: () => undefined,
        stepInto: () => undefined,
        openSettings: () => undefined,
        openHelp: () => undefined,
        disconnectSession: () => undefined,
        executeExtensionCommand: () => undefined,
      },
      [recent],
      []
    );

    const store = new CommandModeStore();
    store.registerActions(actions);
    expect(store.handleKeyDown(new KeyboardEvent('keydown', { key: 'r', ctrlKey: true, cancelable: true }))).toBe(false);
    expect(reloaded).toBe(0);

    store.updateContext({ connected: true, canReload: true });
    expect(store.handleKeyDown(new KeyboardEvent('keydown', { key: 'r', ctrlKey: true, cancelable: true }))).toBe(true);
    expect(reloaded).toBe(1);

    const recentCmd = store.resolvedCommands().find((c) => c.action.id === 'recent-elf:0');
    expect(recentCmd?.action.label).toBe('Open Recent: app.elf');
    expect(recentCmd ? store.execute(recentCmd) : false).toBe(true);
    expect(openedRecent).toBe('app.elf');
  });
});
