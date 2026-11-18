import { ChangeDetectionStrategy, Component, computed, inject, signal } from '@angular/core';
import { Router } from '@angular/router';
import { Core } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { BoardStore } from '../../core/stores/board.store';
import { DebugStore } from '../../core/stores/debug.store';
import { ProfileStore } from '../../core/stores/profile.store';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { type FlamegraphNode, toIcicleRows } from '../../shared/utils/flamegraph';
import { formatHex32 } from '../../shared/utils/hex';
import {
  type HotspotRow,
  type HotspotSortDir,
  type HotspotSortKey,
  aggregateHotspots,
  nodeMatchesFilter,
  resolveSymbolAddress,
  sortHotspots,
} from './profile-hotspots';
import { ProfileViewService } from './profile-view.service';

@Component({
  selector: 'app-profile-flamegraph-pane',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent],
  templateUrl: './profile-flamegraph-pane.component.html',
  styleUrl: './profile-flamegraph-pane.component.css',
})
export class ProfileFlamegraphPaneComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly profile = inject(ProfileStore);
  private readonly board = inject(BoardStore);
  private readonly debug = inject(DebugStore);
  private readonly router = inject(Router);
  private readonly view = inject(ProfileViewService);

  protected readonly mode = signal<'flame' | 'icicle'>('flame');
  protected readonly symbolFilter = signal<string>('');
  protected readonly zoomNodeId = signal<string | null>(null);
  protected readonly selectedNodeId = signal<string | null>(null);
  protected readonly sortKey = signal<HotspotSortKey>('selfPct');
  protected readonly sortDir = signal<HotspotSortDir>('desc');

  protected readonly modeSummary = computed(() => {
    const core = this.view.coreFilter();
    const coreLabel = core === 'both' ? 'BOTH CORES' : core === 'cpu1' ? 'CPU1 M33' : 'CPU0 M85';
    const orient = this.mode() === 'icicle' ? 'TOP-DOWN' : 'BOTTOM-UP';
    return `${coreLabel} · ${orient} · ${this.profile.flamegraph().totalSamples} SAMPLES`;
  });

  protected readonly zoomedNode = computed<FlamegraphNode | null>(() => {
    const id = this.zoomNodeId();
    return id ? this.profile.flamegraph().nodes.find((n) => n.id === id) ?? null : null;
  });

  protected readonly selectedFrame = computed<FlamegraphNode | null>(() => {
    const fg = this.profile.flamegraph();
    if (fg.totalSamples === 0) return null;
    const selId = this.selectedNodeId() ?? this.zoomNodeId();
    if (selId) {
      const match = fg.nodes.find((n) => n.id === selId);
      if (match) return match;
    }
    return fg.hotspot ?? fg.nodes[0] ?? null;
  });

  protected readonly selectedSelfPct = computed(() => {
    const fg = this.profile.flamegraph();
    const sel = this.selectedFrame();
    if (!sel || fg.totalSamples <= 0) return '0.0';
    return ((sel.selfSamples / fg.totalSamples) * 100).toFixed(1);
  });

  protected readonly selectedLocation = computed(() => {
    const sel = this.selectedFrame();
    if (!sel) return '';
    const syms = this.activeSymbols();
    const addr = resolveSymbolAddress(sel.name, syms);
    return addr !== null ? formatHex32(addr) : 'ELF symbol';
  });

  protected readonly displayRows = computed<FlamegraphNode[][]>(() => {
    const view = this.profile.flamegraph();
    const rawRows = this.mode() === 'icicle' ? view.rows : toIcicleRows(view);
    const zoom = this.zoomedNode();
    if (!zoom) return rawRows;
    const zEnd = zoom.startPct + zoom.widthPct;
    return rawRows
      .map((row) => row.filter((n) => n.startPct >= zoom.startPct - 0.01 && n.startPct + n.widthPct <= zEnd + 0.01))
      .filter((row) => row.length > 0);
  });

  protected readonly sortedHotspots = computed<HotspotRow[]>(() => {
    const core = this.view.activeCaptureCore();
    const rows = aggregateHotspots(this.profile.flamegraph(), this.activeSymbols(), core, this.symbolFilter());
    return sortHotspots(rows, this.sortKey(), this.sortDir()).slice(0, 12);
  });

  protected scaledLeft(node: FlamegraphNode): number {
    const zoom = this.zoomedNode();
    if (!zoom || zoom.widthPct <= 0) return Math.max(0, node.startPct);
    return Math.max(0, Math.min(100, ((node.startPct - zoom.startPct) / zoom.widthPct) * 100));
  }

  protected scaledWidth(node: FlamegraphNode): number {
    const zoom = this.zoomedNode();
    if (!zoom || zoom.widthPct <= 0) return Math.max(0, Math.min(100, node.widthPct));
    const left = this.scaledLeft(node);
    return Math.max(0, Math.min(100 - left, (node.widthPct / zoom.widthPct) * 100));
  }

  protected isNodeDimmed(node: FlamegraphNode): boolean {
    const q = this.symbolFilter().trim();
    if (!q) return false;
    return !nodeMatchesFilter(node.name, q);
  }

  protected onSymbolFilter(event: Event): void {
    this.symbolFilter.set((event.target as HTMLInputElement).value);
  }

  protected selectFrame(node: FlamegraphNode): void {
    this.selectedNodeId.set(node.id);
    this.zoomNodeId.set(node.id);
  }

  protected selectHotspotRow(symbol: string): void {
    const match = this.profile.flamegraph().nodes.find((n) => n.depth > 0 && n.name === symbol);
    if (match) this.selectedNodeId.set(match.id);
  }

  protected resetZoom(): void {
    this.zoomNodeId.set(null);
  }

  protected toggleSort(key: HotspotSortKey): void {
    if (this.sortKey() === key) {
      this.sortDir.update((d) => (d === 'desc' ? 'asc' : 'desc'));
    } else {
      this.sortKey.set(key);
      this.sortDir.set(key === 'symbol' ? 'asc' : 'desc');
    }
  }

  protected sortGlyph(key: HotspotSortKey): string {
    if (this.sortKey() !== key) return '';
    return this.sortDir() === 'desc' ? '↓' : '↑';
  }

  protected captureAll(): void {
    this.zoomNodeId.set(null);
    this.selectedNodeId.set(null);
    void this.view.captureActiveWindow();
  }

  protected async jumpToDebug(row: HotspotRow, event: Event): Promise<void> {
    event.stopPropagation();
    await this.debug.selectCore(row.core);
    if (row.address !== null && this.rpc.isConnected()) {
      await this.debug.refreshDisassembly(row.core, row.address, 32);
    }
    await this.router.navigate(['/debug'], {
      queryParams: {
        symbol: row.symbol,
        ...(row.address !== null ? { addr: formatHex32(row.address) } : {}),
      },
    });
  }

  private activeSymbols() {
    return this.view.activeCaptureCore() === Core.Cpu1
      ? this.board.cpu1ElfSymbols()
      : this.board.cpu0ElfSymbols();
  }
}
