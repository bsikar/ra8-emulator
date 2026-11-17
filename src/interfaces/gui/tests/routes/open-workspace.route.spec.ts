import { signal } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { provideRouter, Router } from '@angular/router';
import { Core, type WorkspacePage } from 'ra8-rpc-client';
import { beforeEach, describe, expect, it } from 'vitest';
import { appRoutes } from '../../src/app/app.routes';
import { RpcConnectionStore } from '../../src/app/core/rpc/rpc-connection.store';
import { BoardStore } from '../../src/app/core/stores/board.store';
import { WorkspaceStore } from '../../src/app/core/stores/workspace.store';
import { OpenWorkspaceRouteComponent } from '../../src/app/routes/open-workspace.route';

function makeValidArmElf(totalSize = 256): Uint8Array {
  const bytes = new Uint8Array(Math.max(52, totalSize));
  bytes[0] = 0x7f;
  bytes[1] = 0x45;
  bytes[2] = 0x4c;
  bytes[3] = 0x46;
  bytes[4] = 1; // ELFCLASS32
  bytes[5] = 1; // ELFDATA2LSB
  bytes[6] = 1;
  const view = new DataView(bytes.buffer);
  view.setUint16(16, 2, true); // ET_EXEC
  view.setUint16(18, 40, true); // EM_ARM
  view.setUint32(24, 0x0200_0401, true); // e_entry
  return bytes;
}

describe('OpenWorkspaceRouteComponent (Screen 05)', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('rejects non-ELF files without throwing and stages >64 KiB ELF with chunked transport', async () => {
    TestBed.configureTestingModule({ providers: [provideRouter(appRoutes)] });
    const router = TestBed.inject(Router);
    const rpc = TestBed.inject(RpcConnectionStore);
    const board = TestBed.inject(BoardStore);
    rpc.connectionState.set('connected');
    rpc.serverUrl.set('ws://127.0.0.1:4567');
    rpc.connect = async () => true;
    let loadedSize = 0;
    board.loadElfFile = async (_name, bytes) => {
      loadedSize = bytes.length;
      return true;
    };

    const fixture = TestBed.createComponent(OpenWorkspaceRouteComponent);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    const comp = fixture.componentInstance as unknown as {
      stageArtifactBytes: (name: string, path: string, bytes: Uint8Array) => void;
    };

    comp.stageArtifactBytes('bad.bin', 'bad.bin', new Uint8Array([0x00, 0x01, 0x02]));
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="open-error-banner"]')?.textContent).toContain('ELF');
    expect((el.querySelector('[data-testid="open-submit-btn"]') as HTMLButtonElement).disabled).toBe(true);

    const bigElf = makeValidArmElf(70_000);
    comp.stageArtifactBytes('app_large.elf', 'build/app_large.elf', bigElf);
    fixture.detectChanges();
    const summary = el.querySelector('[data-testid="open-elf-summary"]')?.textContent ?? '';
    expect(summary).toContain('0x02000401');
    expect(summary).toContain('Chunked CRC32');

    (el.querySelector('[data-testid="open-submit-btn"]') as HTMLButtonElement).click();
    await fixture.whenStable();
    expect(loadedSize).toBe(70_000);
    expect(document.title).toBe('app_large.elf — RA8 Emulator');
    expect(router.url).toBe('/debug');
  });

  it('browses CAP_WORKSPACE directory entries and stages remote ELF bytes', async () => {
    const elfBytes = makeValidArmElf(512);
    const mockWorkspace = {
      hasWorkspaceCap: signal(true),
      recentWorkspaces: signal([]),
      listWorkspace: async (): Promise<WorkspacePage> => ({
        offset: 0,
        count: 2,
        more: false,
        entriesJson: '[]',
        entries: [
          { name: 'src', kind: 'directory' },
          { name: 'blink.elf', kind: 'file' },
        ],
      }),
      readWorkspaceFile: async () => ({
        version: { kind: 1, size: BigInt(elfBytes.length), modifiedNs: 0n, identity: 1n },
        versionBytes: new Uint8Array(25),
        eof: true,
        bytes: elfBytes,
      }),
      recordRecentWorkspace: () => {},
    };

    TestBed.configureTestingModule({
      providers: [provideRouter(appRoutes), { provide: WorkspaceStore, useValue: mockWorkspace }],
    });
    const fixture = TestBed.createComponent(OpenWorkspaceRouteComponent);
    fixture.autoDetectChanges(true);
    await Promise.resolve();
    await fixture.whenStable();
    fixture.detectChanges();

    const el: HTMLElement = fixture.nativeElement;
    const row = el.querySelector('[data-testid="open-entry-blink.elf"]') as HTMLButtonElement;
    expect(row).toBeTruthy();
    row.click();
    await Promise.resolve();
    await fixture.whenStable();
    fixture.detectChanges();

    const summary = el.querySelector('[data-testid="open-elf-summary"]')?.textContent ?? '';
    expect(summary).toContain('blink.elf');
    expect(summary).toContain('Single-frame Load');
    expect(Core.Cpu0).toBe(0);
  });
});
