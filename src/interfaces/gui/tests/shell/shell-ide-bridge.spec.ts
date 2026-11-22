import { TestBed } from '@angular/core/testing';
import { provideRouter, Router } from '@angular/router';
import { appRoutes } from '../../src/app/app.routes';
import { RpcConnectionStore } from '../../src/app/core/rpc/rpc-connection.store';
import { SearchEverywhereStore } from '../../src/app/core/search/search-everywhere.store';
import { BoardStore } from '../../src/app/core/stores/board.store';
import { DebugStore } from '../../src/app/core/stores/debug.store';
import { RecentElfRepository } from '../../src/app/core/stores/recent-elf-db';
import { RECENT_ELF_REPOSITORY, RecentElfStore } from '../../src/app/core/stores/recent-elf.store';
import { RemoteHostsStore } from '../../src/app/core/stores/remote-hosts.store';
import { WorkspaceStore } from '../../src/app/core/stores/workspace.store';
import { VimStore } from '../../src/app/core/vim/vim.store';
import { CommandModeStore } from '../../src/app/shell/command-mode.store';
import { registerShellExHandlers, registerShellSearchProviders } from '../../src/app/shell/shell-ide-bridge';

describe('shell-ide-bridge', () => {
  it('registers Search Everywhere providers, quick jumps, and Vim :ex handlers cleanly', async () => {
    TestBed.configureTestingModule({
      providers: [
        provideRouter(appRoutes),
        { provide: RECENT_ELF_REPOSITORY, useValue: new RecentElfRepository(null) },
      ],
    });
    const deps = {
      router: TestBed.inject(Router),
      rpc: TestBed.inject(RpcConnectionStore),
      board: TestBed.inject(BoardStore),
      debug: TestBed.inject(DebugStore),
      workspace: TestBed.inject(WorkspaceStore),
      recentElf: TestBed.inject(RecentElfStore),
      remoteHosts: TestBed.inject(RemoteHostsStore),
      cmdMode: TestBed.inject(CommandModeStore),
      searchEverywhere: TestBed.inject(SearchEverywhereStore),
      vim: TestBed.inject(VimStore),
    };

    deps.cmdMode.registerActions([
      { id: 'act-1', label: 'Open Debug View', category: 'navigation', run: () => undefined },
    ]);

    const unsubSearch = registerShellSearchProviders(deps);
    const unsubEx = registerShellExHandlers(deps);

    deps.searchEverywhere.setQuery('PC');
    expect(deps.searchEverywhere.results().some((r) => r.category === 'symbols' && r.title === 'PC')).toBe(true);

    deps.searchEverywhere.setQuery('0x20001000');
    await deps.searchEverywhere.executeResult();
    expect(deps.debug.memoryAddress()).toBe(0x2000_1000);

    await deps.vim.executeExCommand(':ext');
    expect(deps.cmdMode.extensionsOpen()).toBe(true);
    await deps.vim.executeExCommand(':help');
    expect(deps.cmdMode.helpOpen()).toBe(true);
    await deps.vim.executeExCommand(':q');
    expect(deps.cmdMode.extensionsOpen()).toBe(false);
    expect(deps.cmdMode.helpOpen()).toBe(false);

    let connectedUrl = '';
    deps.rpc.connect = async (url = '') => {
      connectedUrl = url;
      return false;
    };
    deps.workspace.recordRecentWorkspace({
      id: 'ws-jump',
      name: 'JumpTarget',
      path: '~/work/jump',
      wsUrl: 'ws://127.0.0.1:4777',
      pinned: false,
    });
    deps.searchEverywhere.setQuery('JumpTarget');
    await deps.searchEverywhere.executeResult();
    expect(connectedUrl).toBe('ws://127.0.0.1:4777');

    deps.remoteHosts.saveProfile({
      endpointUrl: 'wss://hil-rack-04.lab:8443/rpc',
      name: 'hil-bench-04.local',
      authMode: 'token',
    });
    deps.searchEverywhere.setQuery('hil-bench-04');
    expect(deps.searchEverywhere.results().some((r) => r.title.includes('hil-bench-04.local'))).toBe(true);

    await deps.vim.executeExCommand(':connect');
    expect(deps.router.url).toBe('/connect');

    unsubSearch();
    unsubEx();
  });
});
