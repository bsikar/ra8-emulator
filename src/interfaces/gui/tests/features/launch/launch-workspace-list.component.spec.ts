import { TestBed } from '@angular/core/testing';
import { LaunchWorkspaceListComponent } from '../../../src/app/features/launch/launch-workspace-list.component';
import type { RecentWorkspaceEntry } from '../../../src/app/core/stores/workspace.store';

describe('LaunchWorkspaceListComponent', () => {
  it('renders populated workspace rows with pin and kebab actions', async () => {
    const entries: RecentWorkspaceEntry[] = [
      {
        id: 'ws-a',
        name: 'RA8P1 Vision',
        path: '~/work/ra8p1',
        wsUrl: 'ws://127.0.0.1:4567',
        pinned: true,
        lastOpenedIso: new Date().toISOString(),
        targetModel: 'EK-RA8P1',
        modeLabel: 'Emulator',
      },
    ];
    const fixture = TestBed.createComponent(LaunchWorkspaceListComponent);
    fixture.componentRef.setInput('workspaces', entries);
    fixture.componentRef.setInput('totalCount', 1);
    let removedId = '';
    let pinnedId = '';
    fixture.componentInstance.removeWorkspace.subscribe((id) => {
      removedId = id;
    });
    fixture.componentInstance.togglePin.subscribe((id) => {
      pinnedId = id;
    });
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('RA8P1 Vision');
    (el.querySelector('[data-testid="workspace-pin-ws-a"]') as HTMLButtonElement).click();
    expect(pinnedId).toBe('ws-a');

    (el.querySelector('[data-testid="workspace-kebab-ws-a"]') as HTMLButtonElement).click();
    await fixture.whenStable();
    const removeBtn = el.querySelector('.kebab-item.is-danger') as HTMLButtonElement;
    removeBtn.click();
    expect(removedId).toBe('ws-a');
  });
});
