import { ChangeDetectionStrategy, Component, computed, inject, input, output, signal } from '@angular/core';
import { RpcConnectionStore } from '../core/rpc/rpc-connection.store';
import { ExecutionStore } from '../core/stores/execution.store';
import { deriveCtlAttachCommand, deriveGdbAttachCommand } from '../core/stores/remote-hosts.types';
import { SectionKickerComponent } from '../shared/ui/section-kicker.component';
import { StatusDotComponent } from '../shared/ui/status-dot.component';
import { TonalButtonComponent } from '../shared/ui/tonal-button.component';

@Component({
  selector: 'app-connection-popover',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent, StatusDotComponent, TonalButtonComponent],
  templateUrl: './connection-popover.component.html',
  styleUrl: './connection-popover.component.css',
})
export class ConnectionPopoverComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly execution = inject(ExecutionStore);

  public readonly open = input.required<boolean>();
  public readonly closed = output<void>();
  public readonly openConnectManager = output<void>();

  protected readonly customGdbPort = signal<number | null>(null);
  protected readonly gdbCommand = computed(() =>
    deriveGdbAttachCommand(this.rpc.serverUrl(), this.customGdbPort())
  );
  protected readonly ctlCommand = computed(() => deriveCtlAttachCommand());

  protected onGdbPortInput(event: Event): void {
    const raw = (event.target as HTMLInputElement).value.trim();
    if (!raw) {
      this.customGdbPort.set(null);
      return;
    }
    const parsed = Number.parseInt(raw, 10);
    if (Number.isInteger(parsed) && parsed > 0 && parsed <= 65535) {
      this.customGdbPort.set(parsed);
    }
  }

  protected toggleObserve(): void {
    const next = !this.rpc.observeOnly();
    this.rpc.setObserveOnly(next);
    this.rpc.pushToast(
      next ? 'Switched to Observe mode (read-only)' : 'Switched to Full Control mode',
      'neutral'
    );
  }

  protected copyCommand(cmd: string, label: string): void {
    if (typeof navigator !== 'undefined' && navigator.clipboard?.writeText) {
      void navigator.clipboard.writeText(cmd);
    }
    this.rpc.pushToast(`Copied ${label} command`, 'neutral');
  }

  protected disconnectSession(): void {
    this.rpc.disconnect(true);
    this.closed.emit();
  }
}
