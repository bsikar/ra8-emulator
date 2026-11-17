import { ChangeDetectionStrategy, Component, input, output, signal } from '@angular/core';
import type { RecentWorkspaceEntry } from '../../core/stores/workspace.store';
import { TonalButtonComponent } from '../../shared/ui/tonal-button.component';
import {
  formatRelativeTime,
  formatWorkspaceHeaderMeta,
  formatWorkspaceSubline,
} from './launch-commands';
import { LaunchConnectBarComponent } from './launch-connect-bar.component';
import { LaunchIconComponent } from './launch-icons.component';

@Component({
  selector: 'app-launch-workspace-list',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [LaunchConnectBarComponent, LaunchIconComponent, TonalButtonComponent],
  styleUrl: './launch-workspace-list.component.css',
  template: `
    <section class="index-card" aria-label="Workspace index" data-testid="workspace-index-card">
      <div class="card-head">
        <span class="es-kicker">WORKSPACE INDEX</span>
        <span class="es-kicker">{{ totalCount() > 0 ? 'MODIFIED' : 'EMPTY' }}</span>
      </div>

      @if (workspaces().length > 0) {
        <div class="ws-list" role="listbox" aria-label="Recent workspaces">
          @for (item of workspaces(); track item.id; let idx = $index) {
            <div
              class="ws-row"
              [class.is-selected]="idx === selectedIndex()"
              [attr.data-testid]="'workspace-row-' + item.id"
              (mouseenter)="selectedChange.emit(idx)"
            >
              <button
                type="button"
                role="option"
                class="ws-row-main"
                [attr.aria-selected]="idx === selectedIndex()"
                (click)="openWorkspace.emit(item)"
              >
                <span class="ws-line-top">
                  <span class="ws-name">{{ item.name }}</span>
                  @if (headerMeta(item)) {
                    <span class="ws-sep" aria-hidden="true">·</span>
                    <span class="es-meta ws-meta">{{ headerMeta(item) }}</span>
                  }
                </span>
                <span class="es-subline ws-subline">{{ subline(item) }}</span>
              </button>

              <div class="ws-row-right">
                <span class="ws-age">{{ relativeAge(item.lastOpenedIso) }}</span>

                <button
                  type="button"
                  class="icon-btn"
                  [class.is-pinned]="item.pinned"
                  [attr.aria-label]="item.pinned ? 'Unpin ' + item.name : 'Pin ' + item.name"
                  [attr.data-testid]="'workspace-pin-' + item.id"
                  (click)="$event.stopPropagation(); togglePin.emit(item.id)"
                >
                  <app-launch-icon name="pin" [size]="15" [filled]="item.pinned" />
                </button>

                <div class="kebab-wrap">
                  <button
                    type="button"
                    class="icon-btn"
                    [attr.aria-label]="'Workspace actions for ' + item.name"
                    [attr.aria-expanded]="openMenuId() === item.id"
                    [attr.data-testid]="'workspace-kebab-' + item.id"
                    (click)="$event.stopPropagation(); toggleMenu(item.id)"
                  >
                    <app-launch-icon name="kebab" [size]="15" />
                  </button>

                  @if (openMenuId() === item.id) {
                    <div class="kebab-menu" role="menu" (click)="$event.stopPropagation()">
                      <button type="button" role="menuitem" class="kebab-item" (click)="runMenuOpen(item)">
                        Open &amp; Connect
                      </button>
                      <button type="button" role="menuitem" class="kebab-item" (click)="runMenuPin(item.id)">
                        {{ item.pinned ? 'Unpin Workspace' : 'Pin Workspace' }}
                      </button>
                      <button type="button" role="menuitem" class="kebab-item is-danger" (click)="runMenuRemove(item.id)">
                        Remove from Index
                      </button>
                    </div>
                  }
                </div>
              </div>
            </div>
          }
        </div>
      } @else if (totalCount() > 0) {
        <div class="empty-filter">
          <p class="es-meta">No workspaces match "{{ filterQuery() }}".</p>
          <app-tonal-button variant="ghost" (pressed)="clearFilter.emit()">Clear filter</app-tonal-button>
        </div>
      } @else {
        <div class="empty-body" data-testid="launch-empty-state">
          <app-launch-connect-bar
            [embedded]="true"
            subtitle="No saved workspaces yet. Connect a WebSocket RPC endpoint, open an artifact, or create a workspace."
            [wsUrl]="wsUrl()"
            [connected]="connected()"
            [hasError]="hasError()"
            [connectionState]="connectionState()"
            [savedHosts]="savedHosts()"
            (wsUrlChange)="wsUrlChange.emit($event)"
            (connectPressed)="connectPressed.emit()"
            (disconnectPressed)="disconnectPressed.emit()"
            (connectHost)="connectHost.emit($event)"
          />

          <div class="empty-footer">
            <p class="es-subline drop-hint">Drop .elf, .board, or .tar.gz anywhere to begin.</p>
            <div class="empty-actions">
              <button type="button" class="es-ghost-link" (click)="openArtifact.emit()">Open Workspace</button>
              <button type="button" class="es-ghost-link" (click)="createWorkspace.emit()">+ New Workspace</button>
            </div>
          </div>
        </div>
      }
    </section>
  `,
})
export class LaunchWorkspaceListComponent {
  public readonly workspaces = input.required<readonly RecentWorkspaceEntry[]>();
  public readonly totalCount = input<number>(0);
  public readonly selectedIndex = input<number>(0);
  public readonly filterQuery = input<string>('');
  public readonly savedHosts = input<readonly string[]>([]);
  public readonly wsUrl = input<string>('');
  public readonly connected = input<boolean>(false);
  public readonly hasError = input<boolean>(false);
  public readonly connectionState = input<string>('disconnected');

  public readonly selectedChange = output<number>();
  public readonly openWorkspace = output<RecentWorkspaceEntry>();
  public readonly togglePin = output<string>();
  public readonly removeWorkspace = output<string>();
  public readonly clearFilter = output<void>();
  public readonly wsUrlChange = output<string>();
  public readonly connectPressed = output<void>();
  public readonly disconnectPressed = output<void>();
  public readonly connectHost = output<string>();
  public readonly openArtifact = output<void>();
  public readonly createWorkspace = output<void>();

  protected readonly openMenuId = signal<string | null>(null);

  public closeMenus(): void {
    this.openMenuId.set(null);
  }

  protected headerMeta(item: RecentWorkspaceEntry): string {
    return formatWorkspaceHeaderMeta(item);
  }

  protected subline(item: RecentWorkspaceEntry): string {
    return formatWorkspaceSubline(item);
  }

  protected relativeAge(iso: string): string {
    return formatRelativeTime(iso);
  }

  protected toggleMenu(id: string): void {
    this.openMenuId.update((cur) => (cur === id ? null : id));
  }

  protected runMenuOpen(item: RecentWorkspaceEntry): void {
    this.openMenuId.set(null);
    this.openWorkspace.emit(item);
  }

  protected runMenuPin(id: string): void {
    this.openMenuId.set(null);
    this.togglePin.emit(id);
  }

  protected runMenuRemove(id: string): void {
    this.openMenuId.set(null);
    this.removeWorkspace.emit(id);
  }
}
