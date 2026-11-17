import { ChangeDetectionStrategy, Component, signal } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { type BoardPreset, findBoardPreset } from 'ra8-rpc-client';
import { describe, expect, it } from 'vitest';
import { BoardDetailsModalComponent } from '../../../src/app/features/workspace/board-details-modal.component';

@Component({
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [BoardDetailsModalComponent],
  template: `
    <app-board-details-modal
      [preset]="preset()"
      (duplicate)="duplicated = $event.targetId"
      (exported)="exportedText = $event"
      (closed)="closedCount = closedCount + 1"
    />
  `,
})
class DetailsHostComponent {
  public preset = signal<BoardPreset | null>(findBoardPreset('ra8p1') ?? null);
  public duplicated = '';
  public exportedText = '';
  public closedCount = 0;
}

describe('BoardDetailsModalComponent', () => {
  it('renders full EK-RA8P1 silicon & memory map specification and emits duplicate/export/close', async () => {
    TestBed.configureTestingModule({});
    const fixture = TestBed.createComponent(DetailsHostComponent);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('RTK7EKA8P1S01001BE');
    expect(el.textContent).toContain('Ethos-U55');
    expect(el.textContent).toContain('0x8000_0000');

    (el.querySelector('[data-testid="board-details-export-btn"]') as HTMLButtonElement).click();
    (el.querySelector('[data-testid="board-details-duplicate-btn"]') as HTMLButtonElement).click();
    (el.querySelector('[data-testid="board-details-close-btn"]') as HTMLButtonElement).click();

    expect(fixture.componentInstance.exportedText).toContain('version=1');
    expect(fixture.componentInstance.duplicated).toBe('ra8p1');
    expect(fixture.componentInstance.closedCount).toBe(1);
  });
});
