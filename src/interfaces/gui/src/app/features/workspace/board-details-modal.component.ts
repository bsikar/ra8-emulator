import { ChangeDetectionStrategy, Component, computed, input, output } from '@angular/core';
import { type BoardPreset, serializeBoardProfile } from 'ra8-rpc-client';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { TonalButtonComponent } from '../../shared/ui/tonal-button.component';
import { buildBoardDetailsViewModel } from './board-details-spec';

@Component({
  selector: 'app-board-details-modal',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent, TonalButtonComponent],
  template: `
    @if (preset(); as board) {
      <div class="details-backdrop" (click)="closed.emit()">
        <div
          class="details-card"
          role="dialog"
          aria-modal="true"
          aria-label="Board Specification Details"
          data-testid="board-details-modal"
          (click)="$event.stopPropagation()"
        >
          <div class="details-head">
            <div>
              <app-section-kicker [label]="'BOARD SPECIFICATION · ' + (board.partNumber === 'CUSTOM' ? 'CUSTOM' : 'DEFAULT PROFILE')" />
              <h2 class="details-title">{{ vm()?.title }}</h2>
            </div>
            <div class="head-right">
              <span class="es-meta mono">{{ vm()?.kitSubtitle }}</span>
              <button type="button" class="close-x" aria-label="Close details" (click)="closed.emit()">x</button>
            </div>
          </div>

          @if (vm(); as spec) {
            <div class="spec-section">
              <app-section-kicker label="SILICON &amp; COMPUTE TOPOLOGY" />
              @for (row of spec.siliconRows; track row.label) {
                <div class="spec-row">
                  <span class="spec-k">{{ row.label }}</span>
                  <span class="spec-v mono">{{ row.value }}</span>
                </div>
              }
            </div>

            <div class="spec-section">
              <app-section-kicker label="MEMORY MAP (ON-CHIP &amp; EXTERNAL)" />
              @for (row of spec.memoryRows; track row.label) {
                <div class="spec-row">
                  <span class="spec-k mono">{{ row.label }}</span>
                  <span class="spec-v mono">{{ row.value }}</span>
                </div>
              }
            </div>

            <div class="spec-section">
              <app-section-kicker label="FITTED COMPONENTS, EXPANSION &amp; PINOUT" />
              @for (row of spec.fittedRows; track row.label) {
                <div class="spec-row">
                  <span class="spec-k">{{ row.label }}</span>
                  <span class="spec-v mono">{{ row.value }}</span>
                </div>
              }
            </div>
          }

          <div class="details-foot">
            <app-tonal-button variant="ghost" testId="board-details-export-btn" (pressed)="exportBoard(board)">
              Export .board
            </app-tonal-button>
            <div class="foot-actions">
              <app-tonal-button variant="ghost" testId="board-details-duplicate-btn" (pressed)="duplicate.emit(board)">
                Duplicate Board
              </app-tonal-button>
              <app-tonal-button testId="board-details-close-btn" (pressed)="closed.emit()">Close</app-tonal-button>
            </div>
          </div>
        </div>
      </div>
    }
  `,
  styles: [
    `
      .details-backdrop {
        position: fixed;
        inset: 0;
        background: rgba(10, 13, 18, 0.8);
        backdrop-filter: blur(8px);
        display: flex;
        align-items: center;
        justify-content: center;
        z-index: 80;
        padding: 20px;
      }
      .details-card {
        width: min(740px, 100%);
        max-height: calc(100vh - 48px);
        overflow-y: auto;
        background: var(--es-container);
        border: 1px solid var(--es-border-strong);
        border-radius: var(--es-radius-xl);
        padding: 20px 24px;
        display: flex;
        flex-direction: column;
        gap: 16px;
      }
      .details-head,
      .details-foot,
      .head-right,
      .foot-actions {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 12px;
      }
      .details-title {
        margin: 4px 0 0;
        font-size: 16px;
        font-weight: 500;
        color: var(--es-text-primary);
      }
      .close-x {
        border: 0;
        background: transparent;
        color: var(--es-text-muted);
        font-size: 14px;
        cursor: pointer;
        padding: 4px 8px;
      }
      .close-x:hover {
        color: var(--es-text-primary);
      }
      .spec-section {
        display: flex;
        flex-direction: column;
        gap: 6px;
        padding-top: 10px;
        border-top: 1px solid var(--es-divider);
      }
      .spec-row {
        display: flex;
        justify-content: space-between;
        align-items: baseline;
        gap: 16px;
        font-size: 12px;
      }
      .spec-k {
        color: var(--es-text-muted);
        flex-shrink: 0;
      }
      .spec-v {
        color: var(--es-text-secondary);
        text-align: right;
      }
      .details-foot {
        padding-top: 12px;
        border-top: 1px solid var(--es-divider);
      }
    `,
  ],
})
export class BoardDetailsModalComponent {
  public readonly preset = input<BoardPreset | null>(null);
  public readonly closed = output<void>();
  public readonly duplicate = output<BoardPreset>();
  public readonly exported = output<string>();

  protected readonly vm = computed(() => {
    const p = this.preset();
    return p ? buildBoardDetailsViewModel(p) : null;
  });

  protected exportBoard(board: BoardPreset): void {
    const text = serializeBoardProfile(board.profile);
    this.exported.emit(text);
    if (typeof document === 'undefined' || typeof URL === 'undefined') return;
    const blob = new Blob([text], { type: 'text/plain;charset=utf-8' });
    const href = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = href;
    a.download = `${board.targetId.replace(/-/g, '_')}.board`;
    a.click();
    URL.revokeObjectURL(href);
  }
}
