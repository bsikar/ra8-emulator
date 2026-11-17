import { ChangeDetectionStrategy, Component, OnInit, computed, inject, signal } from '@angular/core';
import { Router } from '@angular/router';
import { CAP_ARTIFACTS } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../core/rpc/rpc-connection.store';
import { RewindStore } from '../core/stores/rewind.store';
import { WorkspaceStore } from '../core/stores/workspace.store';
import { buildBundleSummaryRows, formatByteSize } from '../features/bundles/bundle-summary';
import { formatRelativeTime } from '../features/launch/launch-commands';
import { LaunchIconComponent } from '../features/launch/launch-icons.component';
import { SectionKickerComponent } from '../shared/ui/section-kicker.component';
import { StatusDotComponent } from '../shared/ui/status-dot.component';
import { pickBrowserFile } from '../shared/utils/file-picker';

@Component({
  selector: 'app-import-archive-route',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [LaunchIconComponent, SectionKickerComponent, StatusDotComponent],
  templateUrl: './import-archive.route.html',
  styleUrl: './import-archive.route.css',
})
export class ImportArchiveRouteComponent implements OnInit {
  private readonly router = inject(Router);
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly rewind = inject(RewindStore);
  private readonly workspace = inject(WorkspaceStore);

  protected readonly archivePath = signal<string>('');
  protected readonly importing = signal<boolean>(false);
  protected readonly canExportActive = computed(
    () => this.rpc.isConnected() && this.rpc.hasCapability(CAP_ARTIFACTS)
  );
  protected readonly summaryRows = computed(() => {
    const preview = this.rewind.stagedBundlePreview();
    return preview ? buildBundleSummaryRows(preview, this.rewind.stagedBundleSizeBytes()) : [];
  });

  public ngOnInit(): void {
    const stagedName = this.rewind.stagedBundleFileName();
    if (stagedName) {
      this.archivePath.set(stagedName);
    }
  }

  protected goBack(): void {
    void this.router.navigateByUrl('/launch');
  }

  protected onPathInput(event: Event): void {
    const target = event.target;
    if (target instanceof HTMLInputElement) {
      this.archivePath.set(target.value);
    }
  }

  protected async browseArchive(): Promise<void> {
    const file = await pickBrowserFile({
      accept: '.tar,.tar.gz,.tgz',
      description: 'RA8 Session Bundle (.tar / .tar.gz)',
      extensions: ['.tar', '.tar.gz', '.tgz'],
    });
    if (!file) return;
    await this.stageFile(file);
  }

  protected async onFallbackFileSelected(event: Event): Promise<void> {
    const input = event.target;
    if (!(input instanceof HTMLInputElement)) return;
    const file = input.files?.[0];
    input.value = '';
    if (file) await this.stageFile(file);
  }

  protected async stageFile(file: { name: string; arrayBuffer: () => Promise<ArrayBuffer> }): Promise<void> {
    this.archivePath.set(file.name);
    const bytes = new Uint8Array(await file.arrayBuffer());
    const preview = await this.rewind.previewStagedArchive(bytes, file.name);
    if (preview) {
      this.rpc.pushToast(`Verified archive ${file.name} (${preview.entries.length} entries)`, 'neutral');
    }
  }

  protected async exportActiveBundle(): Promise<void> {
    if (!this.canExportActive()) return;
    const exported = await this.rewind.exportArtifactBundle(false);
    if (!exported) return;
    const name = `ra8_session_${Date.now().toString(36)}.tar`;
    this.archivePath.set(name);
    await this.rewind.previewStagedArchive(exported.bytes, name);
    this.rpc.pushToast(`Exported live session bundle (${formatByteSize(exported.bytes.length)})`, 'neutral');
  }

  protected async importStaged(): Promise<void> {
    const preview = this.rewind.stagedBundlePreview();
    const bytes = this.rewind.stagedBundleBytes();
    if (!preview || !bytes || this.importing()) return;
    const fileName = this.rewind.stagedBundleFileName() ?? (this.archivePath().trim() || 'session.tar');
    this.importing.set(true);
    try {
      if (this.rpc.isConnected() && this.rpc.hasCapability(CAP_ARTIFACTS)) {
        const commit = await this.rewind.importArtifactBundle(bytes);
        if (!commit?.accepted) return;
      }
      this.rewind.recordRecentBundle(preview, fileName, bytes.length, this.archivePath() || fileName);
      this.workspace.recordRecentWorkspace({
        id: `arc:${fileName}`,
        name: fileName.replace(/\.(tar\.gz|tgz|tar)$/i, ''),
        path: this.archivePath().trim() || fileName,
        wsUrl: this.rpc.serverUrl(),
        pinned: false,
        modeLabel: preview.manifest?.recording ? 'Full Recording' : 'Session Archive',
        artifactSummary: `${preview.entries.length} entries`,
      });
      this.rpc.pushToast(`Imported bundle ${fileName}`, 'neutral');
      await this.router.navigateByUrl('/rewind');
    } finally {
      this.importing.set(false);
    }
  }

  protected formatBytes(bytes: number): string {
    return formatByteSize(bytes);
  }

  protected formatAge(iso: string): string {
    return formatRelativeTime(iso);
  }
}
