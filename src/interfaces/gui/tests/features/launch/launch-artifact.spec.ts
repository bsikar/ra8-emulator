import { TestBed } from '@angular/core/testing';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { BoardStore } from '../../../src/app/core/stores/board.store';
import { RewindStore } from '../../../src/app/core/stores/rewind.store';
import { WorkspaceStore } from '../../../src/app/core/stores/workspace.store';
import { importLaunchArtifactFile } from '../../../src/app/features/launch/launch-artifact';

describe('launch-artifact helpers', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('indexes a valid ELF32 ARM file offline and requests connect bar', async () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const board = TestBed.inject(BoardStore);
    const rewind = TestBed.inject(RewindStore);
    const workspace = TestBed.inject(WorkspaceStore);

    const elf = new Uint8Array(64);
    elf[0] = 0x7f;
    elf[1] = 0x45;
    elf[2] = 0x4c;
    elf[3] = 0x46;
    elf[4] = 1; // ELF32
    elf[5] = 1; // little endian
    elf[6] = 1;
    const view = new DataView(elf.buffer);
    view.setUint16(16, 2, true); // ET_EXEC
    view.setUint16(18, 40, true); // EM_ARM
    view.setUint32(24, 0x0200_0400, true);

    const file = {
      name: 'boot_signed.elf',
      arrayBuffer: async () => elf.buffer,
      text: async () => '',
    };
    let connectRequested = false;
    await importLaunchArtifactFile(file, {
      wsUrl: 'ws://127.0.0.1:4567',
      rpc,
      board,
      rewind,
      workspace,
      navigate: async () => true,
      onNeedConnect: () => {
        connectRequested = true;
      },
    });

    expect(connectRequested).toBe(true);
    expect(workspace.recentWorkspaces().length).toBe(1);
    expect(workspace.recentWorkspaces()[0]?.entryAddress).toBe('0x02000400');
  });
});
