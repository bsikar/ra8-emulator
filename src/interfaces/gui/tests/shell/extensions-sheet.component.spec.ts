import { TestBed } from '@angular/core/testing';
import type { ExtensionManifest } from '../../src/app/core/extensions/extension-manifest';
import { ExtensionStore } from '../../src/app/core/extensions/extension.store';
import {
  type WorkerLike,
  type WorkerMessageEventLike,
  buildWorkerBootstrapScript,
} from '../../src/app/core/extensions/worker-host';
import { ExtensionsSheetComponent } from '../../src/app/shell/extensions-sheet.component';

function createRealBootstrapWorker(manifest: ExtensionManifest): WorkerLike {
  let active = true;
  const selfScope: {
    onmessage: ((event: WorkerMessageEventLike) => void) | null;
    postMessage: (data: unknown) => void;
  } = {
    onmessage: null,
    postMessage: (data: unknown) => {
      queueMicrotask(() => {
        if (active) hostWorker.onmessage?.({ data });
      });
    },
  };
  const fn = new Function('self', buildWorkerBootstrapScript(manifest)) as (s: typeof selfScope) => void;
  fn(selfScope);

  const hostWorker: WorkerLike = {
    onmessage: null,
    onerror: null,
    postMessage: (data: unknown) => {
      queueMicrotask(() => {
        if (active) selfScope.onmessage?.({ data });
      });
    },
    terminate: () => {
      active = false;
    },
  };
  return hostWorker;
}

describe('ExtensionsSheetComponent', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('shows honest empty state, installs example template, runs command, and toggles/uninstalls', async () => {
    TestBed.configureTestingModule({});
    const store = TestBed.inject(ExtensionStore);
    store.configureRuntimeForTest({ workerFactory: (_url, manifest) => createRealBootstrapWorker(manifest) });

    const fixture = TestBed.createComponent(ExtensionsSheetComponent);
    fixture.componentRef.setInput('open', true);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="ext-empty-state"]')).toBeTruthy();

    (el.querySelector('[data-testid="ext-load-template"]') as HTMLButtonElement).click();
    await new Promise((r) => setTimeout(r, 40));
    await fixture.whenStable();

    expect(el.querySelector('[data-testid="ext-row-ra8.target-inspector"]')).toBeTruthy();
    const runBtn = el.querySelector('[data-testid="ext-run-ra8.targetInspector.snapshot"]') as HTMLButtonElement;
    expect(runBtn.disabled).toBe(false);
    runBtn.click();
    await new Promise((r) => setTimeout(r, 40));
    await fixture.whenStable();

    expect(el.querySelector('[data-testid="ext-panel-ra8.targetInspector.panel"]')).toBeTruthy();
    expect(el.querySelector('[data-testid="ext-messages"]')).toBeTruthy();

    (el.querySelector('[data-testid="ext-toggle-ra8.target-inspector"]') as HTMLButtonElement).click();
    await fixture.whenStable();
    expect(store.extensions()[0]?.enabled).toBe(false);

    (el.querySelector('[data-testid="ext-uninstall-ra8.target-inspector"]') as HTMLButtonElement).click();
    await fixture.whenStable();
    expect(store.extensions().length).toBe(0);
  });

  it('validates custom JSON+JS extension drawer input cleanly', async () => {
    TestBed.configureTestingModule({});
    const store = TestBed.inject(ExtensionStore);
    store.configureRuntimeForTest({ workerFactory: (_url, manifest) => createRealBootstrapWorker(manifest) });

    const fixture = TestBed.createComponent(ExtensionsSheetComponent);
    fixture.componentRef.setInput('open', true);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    (el.querySelector('[data-testid="ext-toggle-install-drawer"]') as HTMLButtonElement).click();
    await fixture.whenStable();

    const jsonBox = el.querySelector('[data-testid="ext-manifest-json"]') as HTMLTextAreaElement;
    jsonBox.value = '{bad json';
    jsonBox.dispatchEvent(new Event('input'));
    (el.querySelector('[data-testid="ext-install-submit"]') as HTMLButtonElement).click();
    await fixture.whenStable();

    expect(el.querySelector('[data-testid="ext-error"]')?.textContent).toContain('Invalid manifest JSON');
  });
});
