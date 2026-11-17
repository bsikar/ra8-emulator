import type { Router } from '@angular/router';
import { formatHex32 } from '../shared/utils/hex';
import type { RpcConnectionStore } from '../core/rpc/rpc-connection.store';
import type { SearchCandidate, SearchEverywhereStore } from '../core/search/search-everywhere.store';
import type { BoardStore } from '../core/stores/board.store';
import type { DebugStore } from '../core/stores/debug.store';
import type { RemoteHostsStore } from '../core/stores/remote-hosts.store';
import type { WorkspaceStore } from '../core/stores/workspace.store';
import type { VimStore } from '../core/vim/vim.store';
import type { CommandModeStore } from './command-mode.store';

export interface ShellBridgeDeps {
  router: Router;
  rpc: RpcConnectionStore;
  board: BoardStore;
  debug: DebugStore;
  workspace: WorkspaceStore;
  remoteHosts?: RemoteHostsStore;
  cmdMode: CommandModeStore;
  searchEverywhere: SearchEverywhereStore;
  vim: VimStore;
}

const CORE_REG_NAMES = ['pc', 'sp', 'lr', 'xpsr', 'r0', 'r1', 'r2', 'r3', 'r4', 'r5', 'r6', 'r7'] as const;

function collectSymbolCandidates(deps: ShellBridgeDeps): SearchCandidate[] {
  const out: SearchCandidate[] = [];
  for (const sym of deps.board.cpu0ElfSymbols()) {
    out.push({
      id: `sym:cpu0:${sym.name}:${sym.address}`,
      category: 'symbols',
      title: sym.name,
      subtitle: `CPU0 ELF symbol · ${formatHex32(sym.address)}`,
      address: sym.address,
      onSelect: () => {
        deps.debug.memoryAddress.set(sym.address);
        void deps.router.navigateByUrl('/debug');
      },
    });
  }
  for (const reg of CORE_REG_NAMES) {
    const val = deps.debug.registers()[reg];
    out.push({
      id: `sym:reg:${reg}`,
      category: 'symbols',
      title: reg.toUpperCase(),
      subtitle: val !== undefined ? `Register · ${formatHex32(val)}` : 'Core register',
      onSelect: () => void deps.router.navigateByUrl('/debug'),
    });
  }
  return out;
}

function collectTextCandidates(deps: ShellBridgeDeps): SearchCandidate[] {
  const out: SearchCandidate[] = [];
  const lines = deps.debug.sourceFileLines();
  const path = deps.debug.sourceLine()?.path ?? 'source';
  for (let i = 0; i < lines.length && i < 200; i++) {
    const lineText = (lines[i] ?? '').trim();
    if (!lineText) continue;
    out.push({
      id: `text:${path}:${i + 1}`,
      category: 'text',
      title: lineText,
      subtitle: `${path}:${i + 1}`,
      path,
      line: i + 1,
      onSelect: () => void deps.router.navigateByUrl('/debug'),
    });
  }
  return out;
}

/** Wires Search Everywhere providers and quick-jump handlers to shell stores. */
export function registerShellSearchProviders(deps: ShellBridgeDeps): () => void {
  const unsubActions = deps.searchEverywhere.registerProvider('shell-actions', () =>
    deps.cmdMode
      .resolvedCommands()
      .filter((item) => item.enabled)
      .map((item) => ({
        id: `action:${item.action.id}`,
        category: 'actions' as const,
        title: item.action.label,
        subtitle: item.action.category,
        shortcut: item.shortcutLabel || undefined,
        onSelect: () => void deps.cmdMode.execute(item),
      }))
  );
  const unsubSymbols = deps.searchEverywhere.registerProvider('shell-symbols', () => collectSymbolCandidates(deps));
  const unsubText = deps.searchEverywhere.registerProvider('shell-text', () => collectTextCandidates(deps));
  const unsubHosts = deps.searchEverywhere.registerProvider('shell-hosts', () =>
    (deps.remoteHosts?.profiles() ?? []).map((host) => ({
      id: `host:${host.id}`,
      category: 'actions' as const,
      title: `Connect: ${host.name}`,
      subtitle: `${host.transportLabel} · ${host.endpointUrl}`,
      onSelect: async () => {
        const ok = await deps.rpc.connect(host.wsUrl, false, { profileName: host.name });
        if (ok) await deps.router.navigateByUrl('/debug');
        else await deps.router.navigateByUrl('/connect');
      },
    }))
  );

  deps.searchEverywhere.registerJumpHandlers({
    onAddress: async (address) => {
      deps.debug.memoryAddress.set(address >>> 0);
      if (deps.rpc.isConnected()) {
        await deps.debug.readMemoryPage(address >>> 0);
      }
      deps.rpc.pushToast(`Jumped to ${formatHex32(address)}`);
      await deps.router.navigateByUrl('/debug');
    },
    onLine: async (line) => {
      deps.rpc.pushToast(`Jumped to line ${line}`);
      await deps.router.navigateByUrl('/debug');
    },
    onWorkspace: async (ws) => {
      deps.workspace.recordRecentWorkspace({ ...ws });
      const ok = await deps.rpc.connect(ws.wsUrl);
      if (ok) {
        deps.workspace.addSavedHost(ws.wsUrl);
        await deps.router.navigateByUrl('/debug');
      } else {
        await deps.router.navigateByUrl('/launch');
      }
    },
  });

  return () => {
    unsubActions();
    unsubSymbols();
    unsubText();
    unsubHosts();
  };
}

/** Registers Vim `:ex` command handlers for `:ext`, `:help`, `:connect`, `:e`, `:0x...`, and `:q`. */
export function registerShellExHandlers(deps: ShellBridgeDeps): () => void {
  const unsubs = [
    deps.vim.registerExHandler('extensions', () => {
      deps.cmdMode.extensionsOpen.set(true);
    }),
    deps.vim.registerExHandler('help', () => {
      deps.cmdMode.helpOpen.set(true);
    }),
    deps.vim.registerExHandler('connect', async (cmd) => {
      if (cmd.kind !== 'connect') return false;
      const targetUrl = cmd.url.trim();
      if (!targetUrl) {
        await deps.router.navigateByUrl('/connect');
        return true;
      }
      const ok = await deps.rpc.connect(targetUrl);
      if (ok) deps.workspace.addSavedHost(targetUrl);
      return true;
    }),
    deps.vim.registerExHandler('edit', (cmd) => {
      if (cmd.kind !== 'edit') return false;
      if (cmd.file) {
        deps.searchEverywhere.openSearch('files', cmd.file);
      } else {
        void deps.router.navigateByUrl('/debug');
      }
      return true;
    }),
    deps.vim.registerExHandler('goto-address', async (cmd) => {
      if (cmd.kind !== 'goto-address') return false;
      deps.debug.memoryAddress.set(cmd.address >>> 0);
      if (deps.rpc.isConnected()) {
        await deps.debug.readMemoryPage(cmd.address >>> 0);
      }
      deps.rpc.pushToast(`Jumped to ${formatHex32(cmd.address)}`);
      return true;
    }),
    deps.vim.registerExHandler('quit', () => {
      deps.cmdMode.closeOverlays();
      deps.searchEverywhere.closeSearch();
    }),
  ];

  return () => {
    for (const unsub of unsubs) unsub();
  };
}
