import { type BoardProfile, Core, inspectElf, parseBoardProfile, parseElfSymbols } from 'ra8-rpc-client';
import type { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import type { BoardStore } from '../../core/stores/board.store';
import type { RecentElfStore } from '../../core/stores/recent-elf.store';
import type { RewindStore } from '../../core/stores/rewind.store';
import type { WorkspaceStore } from '../../core/stores/workspace.store';
import type { BrowserFileHandleLike } from '../../shared/utils/file-picker';
import { formatHex32 } from '../../shared/utils/hex';

const CHUNKED_LOAD_THRESHOLD = 65_536;

export interface StagedElfArtifact {
  name: string;
  sourcePath: string;
  bytes: Uint8Array;
  entryHex: string;
  hasDebugInfo: boolean;
  symbolCount: number;
  chunkedTransfer: boolean;
}

export interface StagedBoardArtifact {
  name: string;
  sourcePath: string;
  rawText: string;
  profile: BoardProfile;
}

export type ParsedStageArtifact =
  | { kind: 'elf'; elf: StagedElfArtifact }
  | { kind: 'board'; board: StagedBoardArtifact }
  | { kind: 'error'; error: string };

export interface ArtifactImportContext {
  wsUrl: string;
  rpc: RpcConnectionStore;
  board: BoardStore;
  rewind: RewindStore;
  workspace: WorkspaceStore;
  recentElf?: RecentElfStore;
  navigate: (url: string) => Promise<boolean>;
  onNeedConnect: () => void;
}

export interface ArtifactFileLike {
  name: string;
  handle?: BrowserFileHandleLike | null;
  arrayBuffer: () => Promise<ArrayBuffer>;
  text: () => Promise<string>;
}

/** Validate raw `.board` or `.elf`/`.axf`/`.ra8app` bytes into a staging payload. */
export function parseArtifactForStaging(
  fileName: string,
  sourcePath: string,
  bytes: Uint8Array
): ParsedStageArtifact {
  if (/\.board$/i.test(fileName)) {
    const rawText = new TextDecoder().decode(bytes);
    try {
      const profile = parseBoardProfile(rawText);
      return { kind: 'board', board: { name: fileName, sourcePath, rawText, profile } };
    } catch (err) {
      return {
        kind: 'error',
        error: err instanceof Error ? err.message : `Invalid board profile: ${fileName}`,
      };
    }
  }

  const header = inspectElf(bytes);
  if (!header.valid) {
    return { kind: 'error', error: header.reason ?? `Invalid ARM32 ELF image (${fileName})` };
  }
  const syms = parseElfSymbols(bytes);
  return {
    kind: 'elf',
    elf: {
      name: fileName,
      sourcePath,
      bytes,
      entryHex: formatHex32(header.entry >>> 0),
      hasDebugInfo: header.hasDebugInfo,
      symbolCount: syms.length,
      chunkedTransfer: bytes.length > CHUNKED_LOAD_THRESHOLD,
    },
  };
}

/** Reads and routes a user-picked `.board` or firmware image into stores and history. */
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
    name: file.name.replace(/\.(elf|axf|ra8app)$/i, ''),
    path: file.name,
    wsUrl: ctx.wsUrl,
    pinned: false,
    modeLabel: 'Prebuilt .elf',
    artifactSummary: file.name,
    entryAddress: formatHex32(header.entry >>> 0),
  });

  if (ctx.rpc.isConnected()) {
    const ok = await ctx.board.loadElfFile(file.name, bytes, Core.Cpu0, { breakAtMain: false });
    if (ok) {
      await ctx.recentElf?.recordLoadedElf({
        fileName: file.name,
        core: Core.Cpu0,
        wsUrl: ctx.wsUrl,
        handle: file.handle ?? null,
        bytes,
      });
      await ctx.navigate('/debug');
    }
  } else {
    ctx.onNeedConnect();
    ctx.rpc.pushToast(`Indexed ${file.name} — connect RPC to upload`);
  }
}

/** Stages a `.tar`/`.tar.gz` bundle into `RewindStore`, records it, and navigates to `/import`. */
export async function importLaunchArchiveFile(file: ArtifactFileLike, ctx: ArtifactImportContext): Promise<void> {
  const bytes = new Uint8Array(await file.arrayBuffer());
  const preview = await ctx.rewind.previewStagedArchive(bytes, file.name);
  if (preview) {
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
  }
  await ctx.navigate('/import');
}
