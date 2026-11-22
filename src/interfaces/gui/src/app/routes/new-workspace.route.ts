import { ChangeDetectionStrategy, Component, inject } from '@angular/core';
import { Router } from '@angular/router';
import { Core } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../core/rpc/rpc-connection.store';
import { BoardStore } from '../core/stores/board.store';
import { RecentElfStore } from '../core/stores/recent-elf.store';
import { WorkspaceStore } from '../core/stores/workspace.store';
import { formatPresetArchSummary } from '../features/launch/launch-commands';
import {
  LaunchNewWorkspaceDialogComponent,
  type NewWorkspacePayload,
} from '../features/launch/launch-new-workspace-dialog.component';

@Component({
  selector: 'app-new-workspace-route',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [LaunchNewWorkspaceDialogComponent],
  template: `
    <app-launch-new-workspace-dialog
      [open]="true"
      [standalone]="true"
      [defaultWsUrl]="rpc.serverUrl()"
      (closed)="goBack()"
      (created)="onCreated($event)"
    />
  `,
})
export class NewWorkspaceRouteComponent {
  private readonly router = inject(Router);
  protected readonly rpc = inject(RpcConnectionStore);
  private readonly board = inject(BoardStore);
  private readonly workspace = inject(WorkspaceStore);
  private readonly recentElf = inject(RecentElfStore);

  protected goBack(): void {
    void this.router.navigateByUrl('/launch');
  }

  protected async onCreated(payload: NewWorkspacePayload): Promise<void> {
    this.board.selectBoardPreset(payload.preset.targetId);
    this.workspace.recordRecentWorkspace({
      id: `ws:${Date.now().toString(36)}`,
      name: payload.name,
      path: payload.path,
      wsUrl: payload.wsUrl,
      pinned: false,
      targetModel: payload.preset.targetId.toUpperCase(),
      archSummary: formatPresetArchSummary(payload.preset),
      modeLabel: payload.modeLabel,
      artifactSummary: payload.cpu0ElfFile?.name ?? `${payload.preset.targetId.replace('-', '_')}.board`,
    });
    if (payload.cpu0ElfFile && this.rpc.isConnected()) {
      const ok = await this.board.loadElfFile(payload.cpu0ElfFile.name, payload.cpu0ElfFile.bytes, Core.Cpu0, {
        breakAtMain: false,
      });
      if (ok) {
        await this.recentElf.recordLoadedElf({
          fileName: payload.cpu0ElfFile.name,
          core: Core.Cpu0,
          wsUrl: payload.wsUrl,
          bytes: payload.cpu0ElfFile.bytes,
        });
        await this.router.navigateByUrl('/debug');
      }
      return;
    }
    this.rpc.pushToast(`Created workspace ${payload.name}`, 'neutral');
    await this.router.navigateByUrl('/launch');
  }
}
