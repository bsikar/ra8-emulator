import { ChangeDetectionStrategy, Component, inject, output, signal } from '@angular/core';
import { Direction, NavQueryKind } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { RewindStore } from '../../core/stores/rewind.store';
import { normalizeSeekTarget } from '../../core/stores/rewind-helpers';
import { type RewindBookmark } from './rewind-model';

@Component({
  selector: 'app-rewind-transport-bar',
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="bar-wrap">
      <div class="bar-row">
        <div class="grp">
          <button type="button" class="mini-btn" [disabled]="!canEdit()" (click)="rewind.play(dirBack, speedMilli())">◀ Reverse</button>
          <button type="button" class="mini-btn" [disabled]="!canEdit()" (click)="rewind.play(dirFwd, speedMilli())">Forward ▶</button>
          <select class="es-select mono" aria-label="Playback speed" [value]="speedPreset()" (change)="onSpeedChange($event)">
            <option value="250">0.25x</option>
            <option value="1000">1x</option>
            <option value="4000">4x</option>
          </select>
          <button type="button" class="mini-btn" data-testid="rewind-seek-zero" [disabled]="!canEdit()" (click)="seekOrigin()">Seek 0</button>
          <button type="button" class="mini-btn" data-testid="rewind-seek-prev" [disabled]="!canEdit()" (click)="rewind.seekPrev()">Step Back</button>
        </div>

        <form class="grp" (submit)="onSeekSubmit($event)">
          <input type="text" class="es-input mono" data-testid="rewind-seek-input" [value]="seekDraft()" (input)="onSeekInput($event)" placeholder="0ns, prev, frame 5, isr prev" />
          <button type="submit" class="mini-btn" data-testid="rewind-seek-btn" [disabled]="!canEdit()">Seek</button>
        </form>

        <div class="grp">
          <button type="button" class="mini-btn mono" [disabled]="!canEdit()" (click)="rewind.seekTo('isr prev')">isr prev</button>
          <button type="button" class="mini-btn mono" [disabled]="!canEdit()" (click)="rewind.seekTo('isr next')">isr next</button>
          <button type="button" class="mini-btn mono" [disabled]="!canEdit()" (click)="rewind.seekTo('rtos prev')">rtos prev</button>
        </div>
      </div>

      <div class="bar-row secondary">
        <form class="grp" (submit)="onNavSubmit($event)">
          <select class="es-select" aria-label="Navigation query kind" [value]="navKind()" (change)="onNavKindChange($event)">
            <option value="frame">Frame</option>
            <option value="iter">Iteration</option>
            <option value="isr">ISR</option>
            <option value="rtos">RTOS</option>
            <option value="marker">Marker</option>
          </select>
          <input type="text" class="es-input short mono" [value]="navArg()" (input)="onNavArgInput($event)" placeholder="Index or name" />
          <button type="submit" class="mini-btn" [disabled]="!rpc.isConnected()">Nav Query</button>
        </form>

        <form class="grp" (submit)="onMarkerSubmit($event)">
          <input type="text" class="es-input short mono" data-testid="rewind-marker-name" [value]="markerName()" (input)="onMarkerNameInput($event)" placeholder="Marker name" />
          <input type="text" class="es-input short mono" data-testid="rewind-marker-place" [value]="markerPlace()" (input)="onMarkerPlaceInput($event)" placeholder="0x02000008 or symbol" />
          <button type="submit" class="mini-btn" data-testid="rewind-marker-btn" [disabled]="!canEdit()">Set Marker</button>
        </form>
      </div>

      @if (rewind.pendingForkPrompt()) {
        <div class="fork-banner" data-testid="rewind-fork-banner" role="alert">
          <span class="fork-msg">Target stopped at historical state. Confirm counterfactual branch fork before continuing or poking state?</span>
          <div class="grp">
            <button type="button" class="mini-btn accent" data-testid="rewind-confirm-fork" (click)="rewind.confirmFork()">Confirm Fork</button>
            <button type="button" class="mini-btn" data-testid="rewind-cancel-fork" (click)="rewind.cancelFork()">Cancel</button>
          </div>
        </div>
      }
    </div>
  `,
  styles: [
    `
      .bar-wrap { display: flex; flex-direction: column; gap: 6px; padding: 8px 12px; border-bottom: 1px solid var(--es-border); background: var(--es-chrome); }
      .bar-row { display: flex; align-items: center; justify-content: space-between; gap: 10px; flex-wrap: wrap; }
      .bar-row.secondary { padding-top: 4px; border-top: 1px solid var(--es-divider); }
      .grp { display: inline-flex; align-items: center; gap: 6px; flex-wrap: wrap; }
      .es-input { width: 176px; background: transparent; border: 0; border-bottom: 1px solid var(--es-border); color: var(--es-text-primary); font-size: 12px; padding: 2px 4px; }
      .es-input.short { width: 122px; }
      .es-select { background: var(--es-container); color: var(--es-text-secondary); border: 1px solid var(--es-border); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 6px; }
      .mini-btn { border: 1px solid var(--es-border); background: transparent; color: var(--es-text-secondary); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 8px; cursor: pointer; }
      .mini-btn.accent { background: var(--es-interactive); border-color: var(--es-signal-cursor); color: var(--es-text-primary); }
      .mini-btn:disabled { opacity: 0.45; cursor: not-allowed; }
      .fork-banner { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 6px 10px; background: var(--es-container); border: 1px solid var(--es-signal-cursor); border-radius: var(--es-radius); font-size: 12px; }
      .fork-msg { color: var(--es-text-primary); }
    `,
  ],
})
export class RewindTransportBarComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly rewind = inject(RewindStore);

  public readonly bookmarkCreated = output<RewindBookmark>();

  protected readonly dirBack = Direction.Back;
  protected readonly dirFwd = Direction.Fwd;
  protected readonly speedPreset = signal<string>('1000');
  protected readonly seekDraft = signal<string>('');
  protected readonly navKind = signal<'frame' | 'iter' | 'isr' | 'rtos' | 'marker'>('iter');
  protected readonly navArg = signal<string>('0');
  protected readonly markerName = signal<string>('');
  protected readonly markerPlace = signal<string>('');

  protected canEdit(): boolean {
    return this.rpc.isConnected() && !this.rpc.observeOnly();
  }

  protected seekOrigin(): void {
    const live = this.rewind.branches().find((b) => b.isLive);
    void this.rewind.seekPoint(live?.id ?? 0, 0);
  }

  protected speedMilli(): bigint {
    return BigInt(Number.parseInt(this.speedPreset(), 10) || 1000);
  }

  protected onSpeedChange(event: Event): void {
    this.speedPreset.set((event.target as HTMLSelectElement).value);
  }

  protected onSeekInput(event: Event): void {
    this.seekDraft.set((event.target as HTMLInputElement).value);
  }

  protected onSeekSubmit(event: Event): void {
    event.preventDefault();
    const norm = normalizeSeekTarget(this.seekDraft());
    if (norm) void this.rewind.seekTo(norm);
  }

  protected onNavKindChange(event: Event): void {
    const val = (event.target as HTMLSelectElement).value;
    if (val === 'frame' || val === 'iter' || val === 'isr' || val === 'rtos' || val === 'marker') {
      this.navKind.set(val);
    }
  }

  protected onNavArgInput(event: Event): void {
    this.navArg.set((event.target as HTMLInputElement).value);
  }

  protected onNavSubmit(event: Event): void {
    event.preventDefault();
    const raw = this.navArg().trim();
    const kindMap: Record<string, NavQueryKind> = {
      frame: NavQueryKind.Frame,
      iter: NavQueryKind.Iteration,
      isr: NavQueryKind.Isr,
      rtos: NavQueryKind.Rtos,
      marker: NavQueryKind.Marker,
    };
    const kind = kindMap[this.navKind()] ?? NavQueryKind.Iteration;
    const isNumeric = /^\d+$/.test(raw);
    void this.rewind.navQuery({
      kind,
      index: isNumeric ? BigInt(raw) : 0n,
      name: isNumeric ? undefined : raw,
    });
  }

  protected onMarkerNameInput(event: Event): void {
    this.markerName.set((event.target as HTMLInputElement).value);
  }

  protected onMarkerPlaceInput(event: Event): void {
    this.markerPlace.set((event.target as HTMLInputElement).value);
  }

  protected async onMarkerSubmit(event: Event): Promise<void> {
    event.preventDefault();
    const name = this.markerName().trim();
    const place = this.markerPlace().trim();
    if (!name || !place) return;
    const res = await this.rewind.setMarker(name, place);
    if (res?.found) {
      this.bookmarkCreated.emit({ name, place, branch: res.branch, r: res.r, virtualNs: res.virtualNs });
      this.markerName.set('');
    }
  }
}
