import { ChangeDetectionStrategy, Component, input } from '@angular/core';
import { SectionKickerComponent } from '../shared/ui/section-kicker.component';

@Component({
  selector: 'app-drop-veil',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent],
  template: `
    @if (visible()) {
      <div class="drop-veil" data-testid="drop-veil" role="status" aria-live="polite">
        <div class="drop-sheet">
          <app-section-kicker label="ARTIFACT DROP" />
          <p class="drop-title">Drop firmware image, board profile, or session archive</p>
          <p class="drop-meta mono">.elf · .ra8app · .board · .tar.gz</p>
        </div>
      </div>
    }
  `,
  styles: [
    `
      .drop-veil {
        position: fixed;
        inset: 0;
        background: rgba(11, 14, 21, 0.82);
        backdrop-filter: blur(8px);
        display: flex;
        align-items: center;
        justify-content: center;
        z-index: 75;
        pointer-events: none;
      }
      .drop-sheet {
        padding: 24px 32px;
        background: var(--es-container);
        border: 1px solid var(--es-border-strong);
        border-radius: var(--es-radius-xl);
        display: flex;
        flex-direction: column;
        gap: 8px;
        text-align: center;
        max-width: 440px;
      }
      .drop-title {
        margin: 0;
        font-size: 15px;
        font-weight: 500;
        color: var(--es-text-primary);
      }
      .drop-meta {
        margin: 0;
        font-size: 12px;
        color: var(--es-text-muted);
      }
    `,
  ],
})
export class DropVeilComponent {
  public readonly visible = input<boolean>(false);
}
