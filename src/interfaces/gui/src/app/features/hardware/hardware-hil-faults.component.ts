import { ChangeDetectionStrategy, Component, computed, inject, signal } from '@angular/core';
import { EventKind } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { HardwareHilStore } from '../../core/stores/hardware-hil.store';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';

export type FaultModeKey =
  | 'disconnected'
  | 'nack'
  | 'stuck'
  | 'garbage'
  | 'slow'
  | 'stretch'
  | 'bus_low';

interface FaultChipSpec {
  id: FaultModeKey;
  label: string;
  paramLabel: string | null;
  defaultParam: string;
}

const FAULT_CHIPS: readonly FaultChipSpec[] = [
  { id: 'disconnected', label: 'disconnected', paramLabel: null, defaultParam: '' },
  { id: 'nack', label: 'nack:N', paramLabel: 'Count (N)', defaultParam: '8' },
  { id: 'stuck', label: 'stuck:0xHH', paramLabel: 'Byte (0xHH)', defaultParam: '0xFF' },
  { id: 'garbage', label: 'garbage:SEED', paramLabel: 'Seed', defaultParam: '42' },
  { id: 'slow', label: 'slow:NS', paramLabel: 'Delay (ns)', defaultParam: '10000' },
  { id: 'stretch', label: 'stretch:NS', paramLabel: 'Stretch (ns)', defaultParam: '25000' },
  { id: 'bus_low', label: 'bus_low', paramLabel: null, defaultParam: '' },
];

export function formatFaultModeRule(mode: FaultModeKey, param: string): string {
  if (mode === 'disconnected' || mode === 'bus_low') return mode;
  const clean = param.trim();
  const spec = FAULT_CHIPS.find((c) => c.id === mode);
  const arg = clean || spec?.defaultParam || '';
  return arg ? `${mode}:${arg}` : mode;
}

@Component({
  selector: 'app-hardware-hil-faults',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent],
  template: `
    <div class="hil-box">
      <section class="sec">
        <div class="sec-head">
          <app-section-kicker label="FITTED PARTS" />
          <button type="button" class="mini-btn" data-testid="hardware-hil-refresh" [disabled]="!rpc.isConnected()" (click)="hil.refreshPartsAndPeripherals()">Refresh</button>
        </div>

        <form class="inline-form" (submit)="onPlugSubmit($event)">
          <input type="text" class="es-input mono" data-testid="hardware-plug-input" [value]="plugSpec()" (input)="onPlugInput($event)" placeholder="model@endpoint (e.g. max17048@i2c:riic@0x36)" />
          <button type="submit" class="mini-btn" data-testid="hardware-plug-btn" [disabled]="!rpc.isConnected() || rpc.observeOnly()">+ Plug Component</button>
        </form>

        @if (hil.fittedParts().length > 0) {
          <div class="part-hdr mono es-meta"><span>MODEL / ENDPOINT</span><span>STATE / FAULT</span></div>
          @for (part of hil.fittedParts(); track part.endpoint) {
            <div class="part-row" [class.is-targeted]="faultPart() === part.spec">
              <div class="part-meta">
                <span class="mono part-model">{{ part.model || 'fitted' }}</span>
                <span class="mono es-meta part-endpoint">{{ part.endpoint }}</span>
              </div>
              <div class="part-state">
                <span class="sig-dot" [class.is-fault]="part.activeFault !== null" [class.is-nominal]="part.activeFault === null"></span>
                <span class="mono" [class.fault-tag]="part.activeFault !== null">{{ part.activeFault ?? 'Nominal' }}</span>
              </div>
              <div class="part-actions">
                <button type="button" class="mini-btn" (click)="selectFaultTarget(part.spec)">Target</button>
                <button type="button" class="mini-btn" [disabled]="!rpc.isConnected() || rpc.observeOnly()" (click)="hil.unplugPart(part.endpoint)">Unplug</button>
              </div>
            </div>
          }
        } @else {
          <p class="es-meta note">{{ rpc.isConnected() ? 'No external parts fitted.' : 'Connect a session to inspect HIL peripherals.' }}</p>
        }
      </section>

      <section class="sec">
        <div class="sec-head">
          <app-section-kicker label="FAULT INJECTOR" />
          <button type="button" class="ghost-btn" data-testid="hardware-fault-clear-btn" [disabled]="!rpc.isConnected() || rpc.observeOnly()" (click)="clearFault()">Clear Fault</button>
        </div>
        <input type="text" class="es-input mono" data-testid="hardware-fault-part" [value]="faultPart()" (input)="onFaultPartInput($event)" placeholder="part@endpoint or @endpoint" />
        <div class="chip-grid" role="group" aria-label="Fault injection modes">
          @for (chip of faultChips; track chip.id) {
            <button
              type="button"
              class="chip-btn mono"
              [class.is-active]="selectedMode() === chip.id"
              [attr.data-testid]="'hardware-fault-chip-' + chip.id"
              (click)="selectMode(chip)"
            >
              {{ chip.label }}
            </button>
          }
        </div>
        <div class="fault-apply-row">
          @if (activeChipSpec().paramLabel; as pLabel) {
            <span class="es-meta">{{ pLabel }}:</span>
            <input type="text" class="es-input mono param-input" data-testid="hardware-fault-param" [value]="faultParam()" (input)="onFaultParamInput($event)" />
          }
          <input type="text" class="es-input mono rule-preview" data-testid="hardware-fault-rule" [value]="assembledRule()" (input)="onManualRuleInput($event)" aria-label="Fault rule" />
          <button type="button" class="mini-btn is-primary" data-testid="hardware-fault-inject-btn" [disabled]="!rpc.isConnected() || rpc.observeOnly()" (click)="injectFault()">Apply Fault</button>
        </div>
      </section>

      <section class="sec">
        <div class="sec-head">
          <app-section-kicker label="SESSION HARDWARE EVENTS" />
          <span class="mono es-meta">BUFFER: {{ hil.events().length }}/100</span>
        </div>
        @if (hil.events().length > 0) {
          <div class="evt-list">
            @for (evt of hil.events().slice(0, 12); track evt.id) {
              <div class="evt-row mono">
                <span class="evt-left">
                  <span class="sig-dot" [class.is-fault]="isFaultEvent(evt.kind)" [class.is-nominal]="!isFaultEvent(evt.kind)"></span>
                  <span>{{ evt.label }}</span>
                </span>
                <span class="es-meta">{{ evt.detail }}</span>
              </div>
            }
          </div>
        } @else {
          <p class="es-meta note">No hardware bus events recorded yet.</p>
        }
      </section>
    </div>
  `,
  styles: [
    `
      :host { display: block; height: 100%; min-height: 0; min-width: 0; overflow: auto; }
      .hil-box { display: flex; flex-direction: column; min-width: 0; background: var(--es-canvas); }
      .sec { padding: 10px 12px; border-bottom: 1px solid var(--es-border); display: flex; flex-direction: column; gap: 8px; min-width: 0; }
      .sec-head, .inline-form, .part-row, .part-actions, .fault-apply-row, .evt-row, .part-hdr, .part-state, .evt-left { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
      .sec-head, .part-row, .evt-row, .part-hdr { justify-content: space-between; }
      .part-row { padding: 4px 0; border-bottom: 1px solid var(--es-divider); }
      .part-row.is-targeted { background: var(--es-code-active-bg); }
      .part-meta { display: flex; flex-direction: column; min-width: 0; flex: 1; }
      .part-model { font-size: 12px; color: var(--es-text-primary); }
      .part-endpoint { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .part-state { font-size: 12px; color: var(--es-text-secondary); }
      .sig-dot { width: 5px; height: 5px; border-radius: var(--es-radius-full); flex-shrink: 0; }
      .sig-dot.is-nominal { background: var(--es-signal-nominal); }
      .sig-dot.is-fault { width: 6px; height: 6px; background: var(--es-signal-fault); }
      .fault-tag { color: var(--es-signal-fault); }
      .chip-grid { display: flex; flex-wrap: wrap; gap: 6px; }
      .chip-btn, .mini-btn { border: 1px solid var(--es-border); background: transparent; color: var(--es-text-secondary); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 8px; cursor: pointer; }
      .chip-btn.is-active, .mini-btn.is-primary { background: var(--es-interactive); border-color: var(--es-signal-cursor); color: var(--es-text-primary); }
      .mini-btn:disabled { opacity: 0.45; cursor: not-allowed; }
      .ghost-btn { border: 0; background: transparent; color: var(--es-text-secondary); font-size: 12px; cursor: pointer; padding: 0; }
      .ghost-btn:disabled { opacity: 0.45; cursor: not-allowed; }
      .es-input { flex: 1; min-width: 0; background: transparent; border: 0; border-bottom: 1px solid var(--es-border); color: var(--es-text-primary); font-size: 12px; padding: 3px 2px; }
      .param-input { max-width: 84px; }
      .rule-preview { max-width: 120px; }
      .evt-list { display: flex; flex-direction: column; gap: 4px; }
      .evt-row { font-size: 12px; color: var(--es-text-secondary); }
      .note { margin: 0; font-size: 12px; }
    `,
  ],
})
export class HardwareHilFaultsComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly hil = inject(HardwareHilStore);

  protected readonly faultChips = FAULT_CHIPS;
  protected readonly plugSpec = signal<string>('');
  protected readonly faultPart = signal<string>('');
  protected readonly selectedMode = signal<FaultModeKey>('nack');
  protected readonly faultParam = signal<string>('8');
  protected readonly manualRuleOverride = signal<string | null>(null);

  protected readonly activeChipSpec = computed(
    () => FAULT_CHIPS.find((c) => c.id === this.selectedMode()) ?? FAULT_CHIPS[1]!
  );

  protected readonly assembledRule = computed(
    () => this.manualRuleOverride() ?? formatFaultModeRule(this.selectedMode(), this.faultParam())
  );

  protected isFaultEvent(kind: EventKind): boolean {
    return kind === EventKind.FaultSet;
  }

  protected onPlugInput(event: Event): void {
    this.plugSpec.set((event.target as HTMLInputElement).value);
  }

  protected async onPlugSubmit(event: Event): Promise<void> {
    event.preventDefault();
    const spec = this.plugSpec().trim();
    if (!spec) return;
    if (await this.hil.plugPart(spec)) {
      this.faultPart.set(spec);
      this.plugSpec.set('');
    }
  }

  protected selectFaultTarget(spec: string): void {
    this.faultPart.set(spec);
  }

  protected onFaultPartInput(event: Event): void {
    this.faultPart.set((event.target as HTMLInputElement).value);
  }

  protected selectMode(chip: FaultChipSpec): void {
    this.selectedMode.set(chip.id);
    this.faultParam.set(chip.defaultParam);
    this.manualRuleOverride.set(null);
  }

  protected onFaultParamInput(event: Event): void {
    this.faultParam.set((event.target as HTMLInputElement).value);
    this.manualRuleOverride.set(null);
  }

  protected onManualRuleInput(event: Event): void {
    this.manualRuleOverride.set((event.target as HTMLInputElement).value);
  }

  protected injectFault(): void {
    const part = this.faultPart().trim();
    const rule = this.assembledRule().trim();
    if (part && rule) void this.hil.injectFault(part, rule);
  }

  protected clearFault(): void {
    const raw = this.faultPart().trim();
    if (!raw) return;
    const at = raw.indexOf('@');
    const endpoint = at >= 0 ? raw.slice(at + 1) : raw;
    void this.hil.clearFault(endpoint);
  }
}
