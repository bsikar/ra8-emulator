import { TestBed } from '@angular/core/testing';
import { provideRouter, Router } from '@angular/router';
import { beforeEach, describe, expect, it } from 'vitest';
import { appRoutes } from '../../src/app/app.routes';
import { RewindStore } from '../../src/app/core/stores/rewind.store';
import { ImportArchiveRouteComponent } from '../../src/app/routes/import-archive.route';

function makeTar(manifest: Record<string, unknown>): Uint8Array {
  const payload = new TextEncoder().encode(JSON.stringify(manifest));
  const paddedLen = Math.ceil(payload.length / 512) * 512;
  const tar = new Uint8Array(512 + paddedLen + 1024);
  const enc = new TextEncoder();
  tar.set(enc.encode('manifest.json'), 0);
  tar.set(enc.encode('0000644\0'), 100);
  tar.set(enc.encode('0000000\0'), 108);
  tar.set(enc.encode('0000000\0'), 116);
  tar.set(enc.encode(`${payload.length.toString(8).padStart(11, '0')}\0`), 124);
  tar.set(enc.encode('00000000000\0'), 136);
  tar.fill(0x20, 148, 156);
  tar[156] = 0x30;
  tar.set(enc.encode('ustar\0'), 257);
  tar.set(enc.encode('00'), 263);
  let sum = 0;
  for (let i = 0; i < 512; i++) sum += tar[i] ?? 0;
  tar.set(enc.encode(`${sum.toString(8).padStart(6, '0')}\0 `), 148);
  tar.set(payload, 512);
  return tar;
}

describe('ImportArchiveRouteComponent', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('shows honest empty state, stages valid USTAR bundle, records history, and rejects corrupt archives', async () => {
    TestBed.configureTestingModule({ providers: [provideRouter(appRoutes)] });
    const router = TestBed.inject(Router);
    const rewind = TestBed.inject(RewindStore);
    const fixture = TestBed.createComponent(ImportArchiveRouteComponent);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="import-empty-staged"]')).toBeTruthy();
    expect(el.querySelector('[data-testid="import-recent-empty"]')).toBeTruthy();

    await rewind.previewStagedArchive(new Uint8Array([0xde, 0xad, 0xbe, 0xef]), 'bad.tar');
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="import-error"]')).toBeTruthy();

    const tarBytes = makeTar({
      format: 'ra8-session-bundle',
      version: 1,
      snapshot_version: 2,
      board: 'ek_ra8d2',
      elf0: { name: 'cpu0.elf', identity: '4a91', size: 842_000 },
      elf1: null,
      recording: true,
    });
    await rewind.previewStagedArchive(tarBytes, 'ci_418_fault.tar');
    fixture.detectChanges();

    expect(el.querySelector('[data-testid="import-staged-summary"]')?.textContent).toContain('ek_ra8d2');
    expect(el.querySelector('[data-testid="import-staged-summary"]')?.textContent).toContain('cpu0.elf');

    (el.querySelector('[data-testid="import-submit-btn"]') as HTMLButtonElement).click();
    await fixture.whenStable();
    expect(rewind.recentBundles().length).toBe(1);
    expect(router.url).toBe('/rewind');
  });
});
