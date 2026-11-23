import { ChangeDetectionStrategy, Component, inject, input, signal } from '@angular/core';
import { Core } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { DebugLabelsStore } from '../../core/stores/debug-labels.store';

@Component({
  selector: 'app-debug-address-label',
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    @if (editing()) {
      <form (submit)="save($event, draft.value)" (keydown.escape)="editing.set(false)">
        <input #draft aria-label="Debugger label" [value]="name()" [maxLength]="frame() === null ? 48 : 40" [disabled]="saving()" />
        <button type="submit" [disabled]="saving()">Save</button>
      </form>
    } @else if (!rpc.observeOnly()) {
      <button type="button" (click)="editing.set(true)" aria-label="Edit debugger label">
        {{ name() || 'Label' }}
      </button>
    } @else if (name()) {
      <span>{{ name() }}</span>
    }
  `,
  styles: `
    :host, form { display: inline-flex; min-width: 0; gap: 4px; }
    button, input {
      border: 1px solid var(--es-border);
      background: var(--es-chrome);
      color: var(--es-text-secondary);
      font-size: 12px;
    }
    input { width: 8rem; }
  `,
})
export class DebugAddressLabelComponent {
  public readonly core = input.required<Core>();
  public readonly address = input<number | null>(null);
  public readonly frame = input<number | null>(null);
  public readonly name = input('');
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly editing = signal(false);
  protected readonly saving = signal(false);
  private readonly labels = inject(DebugLabelsStore);

  protected async save(event: Event, name: string): Promise<void> {
    event.preventDefault();
    if (this.saving()) return;
    this.saving.set(true);
    try {
      if (await this.updateLabel(name.trim())) this.editing.set(false);
    } finally {
      this.saving.set(false);
    }
  }

  private updateLabel(name: string): Promise<boolean> {
    const frame = this.frame();
    if (frame !== null) return this.labels.setLocalLabel(this.core(), frame, this.name(), name);
    const address = this.address();
    return address === null ? Promise.resolve(false) : this.labels.setAddressLabel(this.core(), address, name);
  }
}
