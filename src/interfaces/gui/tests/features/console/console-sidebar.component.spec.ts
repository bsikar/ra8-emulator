import { TestBed } from '@angular/core/testing';
import { BoardStore } from '../../../src/app/core/stores/board.store';
import { ConsoleSidebarComponent } from '../../../src/app/features/console/console-sidebar.component';

describe('ConsoleSidebarComponent', () => {
  it('resolves manual ELF addresses and emits watch trigger additions', async () => {
    TestBed.configureTestingModule({});
    const board = TestBed.inject(BoardStore);
    board.cpu0ElfSymbols.set([{ name: 'handle_uart', address: 0x0200_1200, size: 16, kind: 'func' }]);

    const fixture = TestBed.createComponent(ConsoleSidebarComponent);
    const added: Array<{ pattern: string; pauseOnMatch: boolean }> = [];
    fixture.componentInstance.addRule.subscribe((evt) => added.push(evt));
    fixture.detectChanges();

    const el: HTMLElement = fixture.nativeElement;
    const lookup = el.querySelector('[data-testid="console-symbol-lookup"]') as HTMLInputElement;
    lookup.value = '0x02001204';
    lookup.dispatchEvent(new Event('input'));
    fixture.detectChanges();
    expect(el.textContent).toContain('handle_uart+0x4');

    const pat = el.querySelector('[data-testid="console-trigger-input"]') as HTMLInputElement;
    pat.value = 'PANIC';
    pat.dispatchEvent(new Event('input'));
    pat.closest('form')!.dispatchEvent(new Event('submit'));
    expect(added).toEqual([{ pattern: 'PANIC', pauseOnMatch: true }]);
  });
});
