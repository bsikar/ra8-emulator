import { Core, inspectElf } from 'ra8-rpc-client';
import type { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import type { BoardStore } from '../../core/stores/board.store';
import type { RewindStore } from '../../core/stores/rewind.store';
import type { WorkspaceStore } from '../../core/stores/workspace.store';

export interface ArtifactImportContext {
  wsUrl: string;
  rpc: RpcConnectionStore;
  board: BoardStore;
  rewind: RewindStore;
  workspace: WorkspaceStore;
  navigate: (url: string) => Promise<boolean>;
  onNeedConnect: () => void;
}

export interface ArtifactFileLike {
  name: string;
  arrayBuffer: () => Promise<ArrayBuffer>;
  text: () => Promise<string>;
}

/** Reads and routes a user-picked `.board` or `.elf` file into stores and workspace history. */
export async function importLaunchArtifactFile(file: ArtifactFileLike, ctx: ArtifactImportContext): Promise<void> {
  const lower = file.name.toLowerCase();
  if (lower.endsWith('.board')) {
    const ok = ctx.board.importBoardProfileText(file.name, await file.text());
    if (ok) {
      ctx.workspace.recordRecentWorkspace({
        id: `board:${file.name}`,
        name: file.name.replace(/\.board$/i, ''),
        path: file.name,
        wsUrl: ctx.wsUrl,
        pinned: false,
        modeLabel: 'Board Profile',
        artifactSummary: file.name,
      });
    }
    return;
  }

  const bytes = new Uint8Array(await file.arrayBuffer());
  const header = inspectElf(bytes);
  if (!header.valid) {
    ctx.rpc.reportError('Open artifact failed', new Error(header.reason ?? 'Unsupported file format'));
    return;
  }

  ctx.workspace.recordRecentWorkspace({
    id: `elf:${file.name}`,
    name: file.name.replace(/\.elf$/i, ''),
    path: file.name,
    wsUrl: ctx.wsUrl,
    pinned: false,
    modeLabel: 'Prebuilt .elf',
    artifactSummary: file.name,
    entryAddress: `0x${(header.entry >>> 0).toString(16).padStart(8, '0')}`,
  });

  if (ctx.rpc.isConnected()) {
    const ok = await ctx.board.loadElfFile(file.name, bytes, Core.Cpu0);
    if (ok) await ctx.navigate('/debug');
  } else {
    ctx.onNeedConnect();
    ctx.rpc.pushToast(`Indexed ${file.name} — connect RPC to upload`);
  }
}

/** Stages a `.tar`/`.tar.gz` bundle into `RewindStore`, records it, and navigates to `/rewind`. */
export async function importLaunchArchiveFile(file: ArtifactFileLike, ctx: ArtifactImportContext): Promise<void> {
  const bytes = new Uint8Array(await file.arrayBuffer());
  const preview = await ctx.rewind.previewStagedArchive(bytes);
  if (!preview) return;
  ctx.workspace.recordRecentWorkspace({
    id: `arc:${file.name}`,
    name: file.name.replace(/\.(tar\.gz|tgz|tar)$/i, ''),
    path: file.name,
    wsUrl: ctx.wsUrl,
    pinned: false,
    modeLabel: 'Session Archive',
    artifactSummary: `${preview.entries.length} entries`,
  });
  ctx.rpc.pushToast(`Staged archive ${file.name} (${preview.entries.length} entries)`);
  await ctx.navigate('/rewind');
}
