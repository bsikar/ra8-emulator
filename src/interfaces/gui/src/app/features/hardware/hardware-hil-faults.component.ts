import { ChangeDetectionStrategy, Component, inject, signal } from '@angular/core';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { HardwareHilStore } from '../../core/stores/hardware-hil.store';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';

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
          <input type="text" class="es-input mono" data-testid="hardware-plug-input" [value]="plugSpec()" (input)="onPlugInput($event)" placeholder="tmp102@i2c:sci3:0x48" />
          <button type="submit" class="mini-btn" data-testid="hardware-plug-btn" [disabled]="!rpc.isConnected() || rpc.observeOnly()">Plug</button>
        </form>

        @if (hil.fittedParts().length > 0) {
          @for (part of hil.fittedParts(); track part.endpoint) {
            <div class="part-row">
              <div class="part-meta">
                <span class="mono part-spec">{{ part.spec }}</span>
                @if (part.activeFault) {
                  <span class="fault-tag mono">{{ part.activeFault }}</span>
                }
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
        <app-section-kicker label="FAULT INJECTION" />
        <div class="fault-grid">
          <input type="text" class="es-input mono" data-testid="hardware-fault-part" [value]="faultPart()" (input)="onFaultPartInput($event)" placeholder="part@endpoint or endpoint" />
          <select class="es-select mono" aria-label="Fault preset" [value]="faultRule()" (change)="onPresetChange($event)">
            <option value="nack">nack</option>
            <option value="timeout">timeout</option>
            <option value="crc">crc</option>
            <option value="stuck_low">stuck_low</option>
          </select>
          <input type="text" class="es-input mono" data-testid="hardware-fault-rule" [value]="faultRule()" (input)="onFaultRuleInput($event)" placeholder="nack | crc | timeout" />
        </div>
        <div class="fault-btns">
          <button type="button" class="mini-btn" data-testid="hardware-fault-inject-btn" [disabled]="!rpc.isConnected() || rpc.observeOnly()" (click)="injectFault()">Inject Fault</button>
          <button type="button" class="mini-btn" data-testid="hardware-fault-clear-btn" [disabled]="!rpc.isConnected() || rpc.observeOnly()" (click)="clearFault()">Clear Fault</button>
        </div>

        @if (hil.events().length > 0) {
          <div class="evt-list">
            @for (evt of hil.events().slice(-5).reverse(); track evt.id) {
              <div class="evt-row mono"><span>{{ evt.label }}</span><span class="es-meta">{{ evt.detail }}</span></div>
            }
          </div>
        }
      </section>
    </div>
  `,
  styles: [
    `
      .hil-box { display: flex; flex-direction: column; min-width: 0; }
      .sec { padding: 10px 14px; border-bottom: 1px solid var(--es-border); display: flex; flex-direction: column; gap: 8px; min-width: 0; }
      .sec-head, .inline-form, .part-row, .part-actions, .fault-btns, .evt-row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
      .sec-head, .part-row, .evt-row { justify-content: space-between; }
      .part-meta { display: flex; flex-direction: column; gap: 2px; min-width: 0; flex: 1; }
      .part-spec { font-size: 12px; color: var(--es-text-primary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .fault-tag { font-size: 12px; color: var(--es-signal-fault); }
      .fault-grid { display: grid; grid-template-columns: 1fr auto; gap: 8px; }
      .es-input { flex: 1; min-width: 0; background: transparent; border: 0; border-bottom: 1px solid var(--es-border); color: var(--es-text-primary); font-size: 12px; padding: 3px 2px; }
      .es-select { background: var(--es-container); color: var(--es-text-secondary); border: 1px solid var(--es-border); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 6px; }
      .mini-btn { border: 1px solid var(--es-border); background: transparent; color: var(--es-text-secondary); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 8px; cursor: pointer; }
      .mini-btn:disabled { opacity: 0.45; cursor: not-allowed; }
      .evt-list { display: flex; flex-direction: column; gap: 3px; border-top: 1px solid var(--es-divider); padding-top: 6px; }
      .evt-row { font-size: 12px; color: var(--es-text-secondary); }
      .note { margin: 0; }
    `,
  ],
})
export class HardwareHilFaultsComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly hil = inject(HardwareHilStore);

  protected readonly plugSpec = signal<string>('');
  protected readonly faultPart = signal<string>('');
  protected readonly faultRule = signal<string>('nack');

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

  protected onPresetChange(event: Event): void {
    this.faultRule.set((event.target as HTMLSelectElement).value);
  }

  protected onFaultRuleInput(event: Event): void {
    this.faultRule.set((event.target as HTMLInputElement).value);
  }

  protected injectFault(): void {
    const part = this.faultPart().trim();
    const rule = this.faultRule().trim();
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
