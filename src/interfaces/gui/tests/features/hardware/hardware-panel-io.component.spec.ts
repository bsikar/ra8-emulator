import { TestBed } from '@angular/core/testing';
import { Core, findBoardPreset } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { BoardStore } from '../../../src/app/core/stores/board.store';
import { HardwarePanelIoComponent } from '../../../src/app/features/hardware/hardware-panel-io.component';

describe('HardwarePanelIoComponent', () => {
  it('captures dirty LCD frames for scrubbing and renders headless card when panel is absent', async () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const board = TestBed.inject(BoardStore);

    rpc.connectionState.set('connected');
    const panelPreset = findBoardPreset('ra8d2')!;
    board.selectedPreset.set(panelPreset);
    board.boardProfile.set(panelPreset.profile);

    const fixture = TestBed.createComponent(HardwarePanelIoComponent);
    fixture.detectChanges();
    rpc.lcdDirty$.next({ core: Core.Cpu0, virtualNs: 1000n, x: 0, y: 0, width: 2, height: 2, pixels: new Uint8Array(16).fill(255) });
    fixture.detectChanges();
    expect(fixture.nativeElement.textContent).toContain('#1/1');

    const headless = findBoardPreset('fpb-ra8e1')!;
    board.selectedPreset.set(headless);
    board.boardProfile.set(headless.profile);
    fixture.detectChanges();
    expect(fixture.nativeElement.textContent).toContain('Headless target profile');
    expect(Core.Cpu0).toBe(0);
  });
});
