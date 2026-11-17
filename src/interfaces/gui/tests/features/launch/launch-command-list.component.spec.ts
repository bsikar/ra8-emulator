import { TestBed } from '@angular/core/testing';
import { LaunchCommandListComponent } from '../../../src/app/features/launch/launch-command-list.component';
import { type LaunchCommandItem, type LaunchCommandSection } from '../../../src/app/features/launch/launch-commands';

describe('LaunchCommandListComponent', () => {
  it('renders grouped command sections and emits execute on click', async () => {
    const executed: string[] = [];
    const items: LaunchCommandItem[] = [
      {
        id: 'cmd-1',
        group: 'SESSION & WORKSPACE COMMANDS',
        icon: 'new-workspace',
        label: 'Create New Workspace...',
        description: 'Select board profile',
        shortcut: 'Ctrl + Shift + N',
        keywords: [],
        run: () => executed.push('cmd-1'),
      },
      {
        id: 'cmd-2',
        group: 'IDE & EXTENSIONS',
        icon: 'extensions',
        label: 'Manage Extensions...',
        description: 'Install extensions',
        shortcut: 'Ctrl + Shift + X',
        keywords: [],
        run: () => executed.push('cmd-2'),
      },
    ];
    const sections: LaunchCommandSection[] = [
      { group: 'SESSION & WORKSPACE COMMANDS', items: [items[0]!] },
      { group: 'IDE & EXTENSIONS', items: [items[1]!] },
    ];

    const fixture = TestBed.createComponent(LaunchCommandListComponent);
    fixture.componentRef.setInput('sections', sections);
    fixture.componentRef.setInput('selectedIndex', 1);
    let emittedId = '';
    fixture.componentInstance.execute.subscribe((cmd) => {
      emittedId = cmd.id;
    });
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('SESSION & WORKSPACE COMMANDS');
    expect(el.textContent).toContain('IDE & EXTENSIONS');
    const selectedBtn = el.querySelector('[data-testid="launch-cmd-cmd-2"]') as HTMLButtonElement;
    expect(selectedBtn.classList.contains('is-selected')).toBe(true);
    selectedBtn.click();
    expect(emittedId).toBe('cmd-2');
  });
});
