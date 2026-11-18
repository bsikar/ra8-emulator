import { ChangeDetectionStrategy, Component, inject, input, signal } from '@angular/core';
import { CAP_ARTIFACTS } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { RewindStore } from '../../core/stores/rewind.store';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import {
  type RewindBookmark,
  forkReasonLabel,
  restoreNamedSnapshot,
  saveNamedSnapshot,
} from './rewind-model';

@Component({
  selector: 'app-rewind-branch-sidebar',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent],
  template: `
    <aside class="branch-side">
      <section class="sec">
        <div class="sec-head">
          <app-section-kicker label="EXECUTION BRANCHES" />
          <button type="button" class="mini-btn" data-testid="rewind-refresh-btn" [disabled]="!rpc.isConnected()" (click)="rewind.refreshBranches()">Refresh</button>
        </div>

        @if (rewind.frameStatus(); as fs) {
          <div class="status-meta mono">
            <span>Frames: {{ fs.frames.toString() }}</span>
            <span>RAM: {{ formatKb(fs.ramBytes) }}</span>
          </div>
        }

        @if (!rewind.historySupported()) {
          <p class="es-meta note">
            {{ rpc.isConnected() ? 'Start emulator with --history to record deterministic checkpoints.' : 'Connect a session to inspect execution history.' }}
          </p>
        } @else if (rewind.branches().length > 0) {
          @for (b of rewind.branches(); track b.id) {
            <div class="branch-card" [class.is-live]="b.isLive">
              <div class="card-top">
                <span class="mono">#{{ b.id }} · {{ reasonLabel(b.reason) }}</span>
                <span class="es-meta mono">{{ b.isLive ? 'LIVE' : 'END r' + b.recordedEndR.toString() }}</span>
              </div>
              <div class="card-actions">
                <button type="button" class="mini-btn" [attr.data-testid]="'rewind-switch-' + b.id" [disabled]="b.isLive || rpc.observeOnly()" (click)="rewind.switchBranch(b.id)">Switch</button>
                <button type="button" class="mini-btn" [attr.data-testid]="'rewind-delete-' + b.id" [disabled]="b.id === 0 || b.isLive || rpc.observeOnly()" (click)="rewind.deleteBranch(b.id, true)">Delete</button>
              </div>
            </div>
          }
        }
      </section>

      <section class="sec">
        <app-section-kicker label="BOOKMARKS" />
        @if (bookmarks().length > 0) {
          @for (bm of bookmarks(); track bm.name) {
            <button type="button" class="bm-row mono" (click)="rewind.seekTo('bm ' + bm.name)">
              <span>{{ bm.name }}</span>
              <span class="es-meta">{{ bm.place }}</span>
            </button>
          }
        } @else {
          <p class="es-meta note">Set a marker above to create a seekable bookmark.</p>
        }
      </section>

      <section class="sec">
        <app-section-kicker label="SNAPSHOTS & BUNDLE" />
        <div class="snap-form">
          <input type="text" class="es-input mono" data-testid="rewind-snapshot-name" [value]="snapName()" (input)="onSnapInput($event)" placeholder="checkpoint.ra8snap" />
          <div class="card-actions">
            <button type="button" class="mini-btn" data-testid="rewind-snapshot-save" [disabled]="!canEdit()" (click)="saveSnap()">Save</button>
            <button type="button" class="mini-btn" data-testid="rewind-snapshot-restore" [disabled]="!canEdit()" (click)="restoreSnap()">Restore</button>
            <button type="button" class="mini-btn" [disabled]="!canExport()" (click)="exportBundle()">Export .tar</button>
          </div>
        </div>
      </section>
    </aside>
  `,
  styles: [
    `
      :host { display: block; height: 100%; min-height: 0; min-width: 0; overflow: hidden; }
      .branch-side { display: flex; flex-direction: column; height: 100%; overflow: auto; background: var(--es-canvas); }
      .sec { padding: 10px 12px; border-bottom: 1px solid var(--es-border); display: flex; flex-direction: column; gap: 8px; min-width: 0; }
      .sec-head, .status-meta, .card-top, .card-actions, .bm-row { display: flex; align-items: center; justify-content: space-between; gap: 6px; flex-wrap: wrap; }
      .status-meta { font-size: 12px; color: var(--es-text-muted); }
      .branch-card { padding: 8px; border: 1px solid var(--es-border); border-radius: var(--es-radius); background: var(--es-container); display: flex; flex-direction: column; gap: 6px; font-size: 12px; }
      .branch-card.is-live { border-color: var(--es-signal-cursor); }
      .bm-row { width: 100%; border: 0; border-bottom: 1px solid var(--es-divider); background: transparent; color: var(--es-text-primary); font-size: 12px; padding: 4px 2px; cursor: pointer; text-align: left; }
      .snap-form { display: flex; flex-direction: column; gap: 6px; }
      .es-input { width: 100%; background: transparent; border: 0; border-bottom: 1px solid var(--es-border); color: var(--es-text-primary); font-size: 12px; padding: 3px 2px; }
      .mini-btn { border: 1px solid var(--es-border); background: transparent; color: var(--es-text-secondary); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 8px; cursor: pointer; }
      .mini-btn:disabled { opacity: 0.45; cursor: not-allowed; }
      .note { margin: 0; }
    `,
  ],
})
export class RewindBranchSidebarComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly rewind = inject(RewindStore);

  public readonly bookmarks = input<readonly RewindBookmark[]>([]);
  protected readonly snapName = signal<string>('checkpoint.ra8snap');

  protected reasonLabel = forkReasonLabel;

  protected formatKb(bytes: bigint): string {
    return `${Math.round(Number(bytes) / 1024)} KiB`;
  }

  protected canEdit(): boolean {
    return this.rpc.isConnected() && !this.rpc.observeOnly();
  }

  protected canExport(): boolean {
    return this.rpc.isConnected() && this.rpc.hasCapability(CAP_ARTIFACTS);
  }

  protected onSnapInput(event: Event): void {
    this.snapName.set((event.target as HTMLInputElement).value);
  }

  protected saveSnap(): void {
    void saveNamedSnapshot(this.rpc, this.snapName());
  }

  protected restoreSnap(): void {
    void restoreNamedSnapshot(this.rpc, this.rewind, this.snapName());
  }

  protected async exportBundle(): Promise<void> {
    const res = await this.rewind.exportArtifactBundle(true);
    if (!res) return;
    const bytes = new Uint8Array(res.bytes.byteLength);
    bytes.set(res.bytes);
    const url = URL.createObjectURL(new Blob([bytes], { type: 'application/x-tar' }));
    const link = document.createElement('a');
    link.href = url;
    link.download = 'ra8-history-bundle.tar';
    link.click();
    URL.revokeObjectURL(url);
  }
}
