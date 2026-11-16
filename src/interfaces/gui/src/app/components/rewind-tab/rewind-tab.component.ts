import { CommonModule } from '@angular/common';
import { Component, inject, signal } from '@angular/core';
import { RewindLayoutNode } from '../../models/rewind-tree';
import { EmulatorService } from '../../services/emulator.service';

@Component({
  selector: 'app-rewind-tab',
  standalone: true,
  imports: [CommonModule],
  template: `
    <div class="ob-page">
      <div class="ob-card">
        <div class="ob-card-head">
          <div class="ob-row">
            <h2 class="ob-card-title">Time-Travel Checkpoint Tree (Left -&gt; Right)</h2>
            <span class="ob-pill ob-pill-accent">Causal Path · t=0 Origin Left</span>
          </div>
          <div class="ob-row">
            <button type="button" class="ob-btn ob-btn-sm" (click)="tarInput.click()">
              Import Tarball...
            </button>
            <input #tarInput type="file" accept=".tar.gz,.tgz" hidden (change)="onImportTarball($event)" />
            <button type="button" class="ob-btn ob-btn-sm" (click)="exportTarball()">
              Export Tarball (.tar.gz)
            </button>
            <button type="button" class="ob-btn ob-btn-primary" data-testid="primary-cta" (click)="forkHere()">
              + Fork Here
            </button>
          </div>
        </div>

        @if (emu.forkStatus()?.pending) {
          <div class="ob-banner ob-banner-warn">
            <span>Pending intervention fork on branch {{ emu.forkStatus()?.branch }} ready for confirmation.</span>
            <div class="ob-row">
              <button type="button" class="ob-btn ob-btn-sm" (click)="emu.confirmPendingFork()">Confirm Fork</button>
              <button type="button" class="ob-btn ob-btn-sm ob-btn-ghost" (click)="emu.cancelPendingFork()">Cancel</button>
            </div>
          </div>
        }

        <div class="ob-card-body">
          @if (emu.lastArchiveSummary()) {
            <div class="ob-banner ob-banner-info">
              <span>{{ emu.lastArchiveSummary() }}</span>
            </div>
          }

          <div class="ob-tree-scroll">
            <svg
              data-testid="rewind-tree-svg"
              class="ob-rewind-svg"
              [attr.viewBox]="'0 0 ' + emu.rewindLayout().width + ' ' + emu.rewindLayout().height"
              [attr.width]="emu.rewindLayout().width"
              [attr.height]="emu.rewindLayout().height"
              role="img"
              aria-label="Sideways branching checkpoint timeline">

              <!-- Branch swimlane rules & labels -->
              @for (lane of emu.rewindLayout().branchLanes; track lane.branch) {
                <line
                  x1="12"
                  [attr.y1]="lane.y"
                  [attr.x2]="emu.rewindLayout().width - 16"
                  [attr.y2]="lane.y"
                  stroke="rgba(255,255,255,0.06)"
                  stroke-dasharray="4 4" />
                <text
                  x="16"
                  [attr.y]="lane.y - 22"
                  fill="#A1A1AA"
                  font-size="12"
                  font-family="sans-serif">
                  {{ lane.name }} [{{ lane.reasonBadge }}]
                </text>
              }

              <!-- Cubic Bezier timeline edges opening left-to-right -->
              @for (edge of emu.rewindLayout().edges; track edge.id) {
                <path
                  [attr.d]="edge.pathD"
                  fill="none"
                  [attr.stroke]="edge.isActiveBranch ? '#0A84FF' : (edge.isForkEdge ? '#FFD60A' : 'rgba(255,255,255,0.28)')"
                  [attr.stroke-width]="edge.isActiveBranch ? 2.5 : 1.75" />
              }

              <!-- Checkpoint pills -->
              @for (node of emu.rewindLayout().nodes; track node.id) {
                <g
                  class="ob-chk-node"
                  tabindex="0"
                  role="button"
                  [attr.aria-label]="node.label"
                  (click)="selectCheckpoint(node)"
                  (keydown.enter)="selectCheckpoint(node)">
                  <rect
                    [attr.x]="node.x - node.pillWidth / 2"
                    [attr.y]="node.y - 18"
                    [attr.width]="node.pillWidth"
                    height="36"
                    rx="18"
                    fill="#101012"
                    [attr.stroke]="node.isCursor || selectedNodeId() === node.id ? '#0A84FF' : (node.faultBadge ? '#FF453A' : 'rgba(255,255,255,0.22)')"
                    [attr.stroke-width]="node.isCursor || selectedNodeId() === node.id ? 2 : 1.25" />
                  <text
                    [attr.x]="node.x"
                    [attr.y]="node.y + 4"
                    text-anchor="middle"
                    fill="#F2F2F7"
                    font-size="12"
                    font-family="monospace">
                    {{ node.label }}
                  </text>
                </g>
              }
            </svg>
          </div>
        </div>
      </div>

      <div class="ob-card">
        <div class="ob-card-head">
          <h2 class="ob-card-title">Changed Since Parent</h2>
          <span class="ob-pill">Principle of Truth · Modified State Only</span>
        </div>
        <div class="ob-card-body">
          <div class="ob-table-wrap">
            <table class="ob-table">
              <thead>
                <tr>
                  <th>Entity</th>
                  <th>Parent Baseline</th>
                  <th>Selected Checkpoint</th>
                  <th>Delta</th>
                  <th>Scope</th>
                </tr>
              </thead>
              <tbody>
                @for (row of emu.activeDiffRows(); track row.entity) {
                  <tr class="ob-tr-changed">
                    <td class="mono">{{ row.entity }}</td>
                    <td class="mono">{{ row.beforeVal }}</td>
                    <td class="mono">{{ row.afterVal }}</td>
                    <td class="mono">{{ row.delta }}</td>
                    <td>{{ row.scope }}</td>
                  </tr>
                }
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
  `,
  styles: [
    `:host { display: block; height: 100%; overflow: auto; font-size: 12px; }
     .ob-tree-scroll { overflow-x: auto; background: var(--bg-void); border: 1px solid var(--border-hairline); border-radius: var(--radius-md); padding: 8px; }
     .ob-rewind-svg { display: block; min-width: 100%; }
     .ob-chk-node { cursor: pointer; }`,
  ],
})
export class RewindTabComponent {
  public readonly emu = inject(EmulatorService);
  public readonly selectedNodeId = signal<string | null>('chk_15');

  public async selectCheckpoint(node: RewindLayoutNode): Promise<void> {
    this.selectedNodeId.set(node.id);
    if (this.emu.connectionState() === 'connected') {
      await this.emu.seekTo(`@${node.round}`);
    } else {
      this.emu.showToast(`Selected ${node.label} (round ${node.round})`);
    }
  }

  public async forkHere(): Promise<void> {
    if (this.emu.connectionState() === 'connected') {
      await this.emu.confirmPendingFork();
    } else {
      this.emu.showToast('Branch fork staged from selected checkpoint');
    }
  }

  public async exportTarball(): Promise<void> {
    const archive = await this.emu.exportTimeTravelArchive();
    if (typeof URL !== 'undefined' && typeof URL.createObjectURL === 'function' && typeof document !== 'undefined') {
      const copy = new Uint8Array(archive.bytes.length);
      copy.set(archive.bytes);
      const blob = new Blob([copy.buffer], { type: 'application/gzip' });
      const url = URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href = url;
      link.download = archive.fileName;
      link.click();
      URL.revokeObjectURL(url);
    }
  }

  public async onImportTarball(evt: Event): Promise<void> {
    const file = (evt.target as HTMLInputElement).files?.[0];
    if (!file) return;
    const bytes = new Uint8Array(await file.arrayBuffer());
    await this.emu.importTimeTravelArchive(file.name, bytes);
  }
}
