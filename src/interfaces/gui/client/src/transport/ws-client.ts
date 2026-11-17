/**
 * Complete RA8 Emulator WebSocket RPC client adding backend workspace, build,
 * project, artifact transfer, and target lease methods (`0x0140..0x0193`).
 */

import {
  ArtifactChunk,
  ArtifactCommit,
  ArtifactDescriptor,
  ArtifactExportResult,
  decodeArtifactChunk,
  decodeArtifactCommit,
  decodeArtifactDescriptor,
  decodeArtifactId,
  encodeArtifactBegin,
  encodeArtifactChunk,
  encodeArtifactExport,
  encodeArtifactId,
  encodeArtifactRead,
  streamArtifactExport,
  streamArtifactImport,
} from "../wire/artifacts.js";
import {
  BuildStartArgs,
  BuildStatus,
  decodeBuildId,
  decodeBuildStatus,
  encodeBuildId,
  encodeBuildStart,
} from "../wire/build.js";
import {
  ProjectPrepared,
  decodeProjectPrepared,
  encodeProjectBuild,
  encodeProjectOpen,
} from "../wire/project.js";
import {
  TargetEntry,
  TargetPerformArgs,
  TargetSelection,
  decodeTargetText,
  decodeTargetsList,
  encodeTargetPerform,
  encodeTargetSelection,
} from "../wire/targets.js";
import { Method } from "../wire/types.js";
import {
  WorkspaceContents,
  WorkspaceListArgs,
  WorkspacePage,
  WorkspaceReadArgs,
  WorkspaceVersion,
  WorkspaceWriteArgs,
  decodeWorkspaceContents,
  decodeWorkspacePage,
  decodeWorkspaceVersion,
  decodeWorkspaceWatch,
  encodeWorkspaceList,
  encodeWorkspacePath,
  encodeWorkspaceRead,
  encodeWorkspaceWatch,
  encodeWorkspaceWrite,
} from "../wire/workspace.js";
import { RA8RpcDebugClient } from "./ws-debug.js";

/** Full RA8 Emulator WebSocket RPC Client (`0x0100..0x0193`). */
export class RA8RpcClient extends RA8RpcDebugClient {
  public async workspaceList(args: WorkspaceListArgs): Promise<WorkspacePage> {
    return decodeWorkspacePage(await this.call(Method.WorkspaceList, encodeWorkspaceList(args)));
  }

  public async workspaceStat(path: string): Promise<WorkspaceVersion> {
    return decodeWorkspaceVersion(await this.call(Method.WorkspaceStat, encodeWorkspacePath(path)));
  }

  public async workspaceRead(args: WorkspaceReadArgs): Promise<WorkspaceContents> {
    return decodeWorkspaceContents(await this.call(Method.WorkspaceRead, encodeWorkspaceRead(args)));
  }

  public async workspaceWrite(args: WorkspaceWriteArgs): Promise<WorkspaceVersion> {
    return decodeWorkspaceVersion(await this.call(Method.WorkspaceWrite, encodeWorkspaceWrite(args)));
  }

  public async workspaceWatch(path: string): Promise<number> {
    return decodeWorkspaceWatch(await this.call(Method.WorkspaceWatch, encodeWorkspacePath(path)));
  }

  public workspaceUnwatch(id: number): Promise<boolean> {
    return this.ack(Method.WorkspaceUnwatch, encodeWorkspaceWatch(id));
  }

  public async buildStart(args: BuildStartArgs): Promise<bigint> {
    return decodeBuildId(await this.call(Method.BuildStart, encodeBuildStart(args)));
  }

  public async buildStatus(id: bigint | number): Promise<BuildStatus> {
    return decodeBuildStatus(await this.call(Method.BuildStatus, encodeBuildId(id)));
  }

  public buildCancel(id: bigint | number): Promise<boolean> {
    return this.ack(Method.BuildCancel, encodeBuildId(id));
  }

  public projectOpen(config: string): Promise<boolean> {
    return this.ack(Method.ProjectOpen, encodeProjectOpen(config));
  }

  public projectClose(): Promise<boolean> {
    return this.ack(Method.ProjectClose, new Uint8Array(0));
  }

  public async projectBuild(recipe: string): Promise<bigint> {
    return decodeBuildId(await this.call(Method.ProjectBuild, encodeProjectBuild(recipe)));
  }

  public async projectPrepare(id: bigint | number): Promise<ProjectPrepared> {
    return decodeProjectPrepared(await this.call(Method.ProjectPrepare, encodeBuildId(id)));
  }

  public async artifactsExportBegin(recording = false): Promise<ArtifactDescriptor> {
    return decodeArtifactDescriptor(
      await this.call(Method.ArtifactsExportBegin, encodeArtifactExport(recording))
    );
  }

  public async artifactsExportRead(
    id: bigint | number,
    offset: bigint | number,
    length: number
  ): Promise<ArtifactChunk> {
    return decodeArtifactChunk(
      await this.call(Method.ArtifactsExportRead, encodeArtifactRead(id, offset, length))
    );
  }

  public async artifactsImportBegin(total: bigint | number, sha256: Uint8Array): Promise<bigint> {
    return decodeArtifactId(
      await this.call(Method.ArtifactsImportBegin, encodeArtifactBegin(total, sha256))
    );
  }

  public artifactsImportWrite(
    id: bigint | number,
    offset: bigint | number,
    bytes: Uint8Array
  ): Promise<boolean> {
    return this.ack(Method.ArtifactsImportWrite, encodeArtifactChunk(id, offset, bytes));
  }

  public async artifactsImportEnd(id: bigint | number): Promise<ArtifactCommit> {
    return decodeArtifactCommit(await this.call(Method.ArtifactsImportEnd, encodeArtifactId(id)));
  }

  public artifactsAbort(id: bigint | number): Promise<boolean> {
    return this.ack(Method.ArtifactsAbort, encodeArtifactId(id));
  }

  public exportArtifact(
    recording = false,
    onProgress?: (readBytes: number, totalBytes: number) => void,
    chunkSize?: number
  ): Promise<ArtifactExportResult> {
    return streamArtifactExport(
      (m, a, t) => this.call(m, a, t),
      recording,
      onProgress,
      chunkSize
    );
  }

  public importArtifact(
    bytes: Uint8Array,
    onProgress?: (sentBytes: number, totalBytes: number) => void,
    chunkSize?: number
  ): Promise<ArtifactCommit> {
    return streamArtifactImport(
      (m, a, t) => this.call(m, a, t),
      bytes,
      onProgress,
      chunkSize
    );
  }

  public async targetsList(): Promise<{ json: string; targets: TargetEntry[] }> {
    return decodeTargetsList(await this.call(Method.TargetsList, new Uint8Array(0)));
  }

  public targetsReserve(selection: TargetSelection): Promise<boolean> {
    return this.ack(Method.TargetsReserve, encodeTargetSelection(selection));
  }

  public targetsRelease(): Promise<boolean> {
    return this.ack(Method.TargetsRelease, new Uint8Array(0));
  }

  public async targetsPerform(args: TargetPerformArgs): Promise<string> {
    return decodeTargetText(await this.call(Method.TargetsPerform, encodeTargetPerform(args)));
  }
}
