import { ChangeDetectionStrategy, Component, inject } from '@angular/core';
import { RpcConnectionStore } from '../core/rpc/rpc-connection.store';

@Component({
  selector: 'app-toast-region',
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    @if (rpc.toasts().length > 0) {
      <div class="toast-stack" role="region" aria-label="Status notifications">
        @for (toast of rpc.toasts(); track toast.id) {
          <div class="toast-item" role="status" [class.is-fault]="toast.tone === 'fault'">
            <span class="toast-dot" [class.is-fault]="toast.tone === 'fault'" aria-hidden="true"></span>
            <span class="toast-msg">{{ toast.message }}</span>
            <button
              type="button"
              class="toast-close"
              aria-label="Dismiss notification"
              (click)="rpc.dismissToast(toast.id)"
            >
              ×
            </button>
          </div>
        }
      </div>
    }
  `,
  styles: [
    `
      .toast-stack {
        position: fixed;
        right: 24px;
        bottom: 44px;
        display: flex;
        flex-direction: column;
        gap: 6px;
        z-index: 65;
        max-width: min(440px, calc(100vw - 48px));
      }
      .toast-item {
        display: flex;
        align-items: center;
        gap: 8px;
        padding: 8px 12px;
        background: var(--es-container);
        border: 1px solid var(--es-border);
        border-radius: var(--es-radius-md);
        color: var(--es-text-primary);
        font-size: 12px;
        line-height: 1.35;
      }
      .toast-dot {
        width: 5px;
        height: 5px;
        border-radius: var(--es-radius-full);
        background: var(--es-signal-cursor);
        flex-shrink: 0;
      }
      .toast-dot.is-fault {
        width: 6px;
        height: 6px;
        background: var(--es-signal-fault);
      }
      .toast-msg {
        flex: 1;
        min-width: 0;
      }
      .toast-close {
        border: 0;
        background: transparent;
        color: var(--es-text-muted);
        font-size: 14px;
        line-height: 1;
        padding: 2px 4px;
        cursor: pointer;
      }
      .toast-close:hover {
        color: var(--es-text-primary);
      }
    `,
  ],
})
export class ToastRegionComponent {
  protected readonly rpc = inject(RpcConnectionStore);
}
