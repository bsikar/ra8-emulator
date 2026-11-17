import { TestBed } from '@angular/core/testing';
import { provideRouter, Router } from '@angular/router';
import { describe, expect, it } from 'vitest';
import { appRoutes } from '../../src/app/app.routes';
import { WorkspaceStore } from '../../src/app/core/stores/workspace.store';
import { NewWorkspaceRouteComponent } from '../../src/app/routes/new-workspace.route';

describe('NewWorkspaceRouteComponent (/workspace/new)', () => {
  it('creates a workspace in standalone Screen 04 route and navigates back to /launch', async () => {
    localStorage.clear();
    TestBed.configureTestingModule({ providers: [provideRouter(appRoutes)] });
    const router = TestBed.inject(Router);
    const workspace = TestBed.inject(WorkspaceStore);
    const fixture = TestBed.createComponent(NewWorkspaceRouteComponent);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    (el.querySelector('[data-testid="preset-ra8p1"]') as HTMLButtonElement).click();
    (el.querySelector('[data-testid="new-ws-create-btn"]') as HTMLButtonElement).click();
    await fixture.whenStable();

    expect(workspace.recentWorkspaces().length).toBe(1);
    expect(workspace.recentWorkspaces()[0]?.targetModel).toBe('RA8P1');
    expect(router.url).toBe('/launch');
  });
});
