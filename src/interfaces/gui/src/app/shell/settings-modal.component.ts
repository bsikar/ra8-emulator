import { ChangeDetectionStrategy, Component, inject, input, output, signal } from '@angular/core';
import { Router } from '@angular/router';
import { ExtensionStore } from '../core/extensions/extension.store';
import { RpcConnectionStore } from '../core/rpc/rpc-connection.store';
import {
  type ProbeBindingIdentity,
  PreferencesStore,
  type SwdConnectMode,
  type WorkbenchSchemeId,
} from '../core/stores/preferences.store';
import { RemoteHostsStore } from '../core/stores/remote-hosts.store';
import { VimStore } from '../core/vim/vim.store';
import { SectionKickerComponent } from '../shared/ui/section-kicker.component';
import { StatusDotComponent } from '../shared/ui/status-dot.component';
import { TonalButtonComponent } from '../shared/ui/tonal-button.component';

export type SettingsTabId =
  | 'general'
  | 'appearance'
  | 'recording'
  | 'probes'
  | 'hosts'
  | 'toolchains';

export interface SettingsNavSection {
  id: SettingsTabId;
  label: string;
}

const NAV_SECTIONS: readonly SettingsNavSection[] = [
  { id: 'general', label: 'General & Defaults' },
  { id: 'appearance', label: 'Appearance & Color Schemes' },
  { id: 'recording', label: 'Session Recording' },
  { id: 'probes', label: 'Hardware Probes & HIL' },
  { id: 'hosts', label: 'Remote & SSH Hosts' },
  { id: 'toolchains', label: 'Toolchains & Keybindings' },
];

const FONT_SIZES: readonly number[] = [12, 12.5, 13, 14, 15];
const SWD_MODES: ReadonlyArray<{ id: SwdConnectMode; label: string }> = [
  { id: 'under-reset', label: 'Under Reset' },
  { id: 'normal', label: 'Normal' },
  { id: 'hot-plug', label: 'Hot-Plug' },
];

@Component({
  selector: 'app-settings-modal',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent, StatusDotComponent, TonalButtonComponent],
  templateUrl: './settings-modal.component.html',
  styleUrl: './settings-modal.component.css',
})
export class SettingsModalComponent {
  protected readonly prefsStore = inject(PreferencesStore);
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly vim = inject(VimStore);
  protected readonly extStore = inject(ExtensionStore);
  protected readonly remoteHosts = inject(RemoteHostsStore);
  private readonly router = inject(Router);

  public readonly open = input<boolean>(false);
  public readonly closed = output<void>();
  public readonly openExtensions = output<void>();

  protected readonly navSections = NAV_SECTIONS;
  protected readonly fontSizes = FONT_SIZES;
  protected readonly swdModes = SWD_MODES;
  protected readonly activeTab = signal<SettingsTabId>('general');

  protected selectScheme(id: WorkbenchSchemeId): void {
    this.prefsStore.patch({ colorScheme: id });
  }

  protected onFontSizeChange(event: Event): void {
    if (event.target instanceof HTMLSelectElement) {
      this.prefsStore.patch({ codeFontSizePx: Number.parseFloat(event.target.value) });
    }
  }

  protected onDimZeroToggle(event: Event): void {
    if (event.target instanceof HTMLInputElement) {
      this.prefsStore.patch({ dimZeroRegisters: event.target.checked });
    }
  }

  protected onAutoRecordToggle(event: Event): void {
    if (event.target instanceof HTMLInputElement) {
      this.prefsStore.patch({ autoRecordOnAttach: event.target.checked });
    }
  }

  protected onCheckpointCadenceChange(event: Event): void {
    if (event.target instanceof HTMLSelectElement) {
      this.prefsStore.patch({ checkpointEveryRounds: Number.parseInt(event.target.value, 10) || 64 });
    }
  }

  protected onBindingIdentityChange(event: Event): void {
    if (event.target instanceof HTMLSelectElement) {
      this.prefsStore.patch({ probeBindingIdentity: event.target.value as ProbeBindingIdentity });
    }
  }

  protected onAutoRebindToggle(event: Event): void {
    if (event.target instanceof HTMLInputElement) {
      this.prefsStore.patch({ autoRebindVcom: event.target.checked });
    }
  }

  protected setSwdMode(mode: SwdConnectMode): void {
    this.prefsStore.patch({ defaultSwdConnectMode: mode });
  }

  protected onZigPathInput(event: Event): void {
    if (event.target instanceof HTMLInputElement) {
      this.prefsStore.patch({ toolchainZigPath: event.target.value });
    }
  }

  protected onGdbPortInput(event: Event): void {
    if (event.target instanceof HTMLInputElement) {
      const port = Number.parseInt(event.target.value, 10);
      if (Number.isFinite(port) && port > 0 && port <= 65535) {
        this.prefsStore.patch({ toolchainGdbPort: port });
      }
    }
  }

  protected exportJson(): void {
    const text = this.prefsStore.exportSettingsJson();
    if (typeof document === 'undefined' || typeof URL === 'undefined') return;
    const blob = new Blob([text], { type: 'application/json;charset=utf-8' });
    const href = URL.createObjectURL(blob);
    const anchor = document.createElement('a');
    anchor.href = href;
    anchor.download = 'ra8-settings.json';
    anchor.click();
    URL.revokeObjectURL(href);
    this.rpc.pushToast('Exported settings JSON');
  }

  protected openHostsManager(): void {
    this.closed.emit();
    void this.router.navigateByUrl('/connect');
  }

  protected saveAndClose(): void {
    this.prefsStore.applySchemeCssVars();
    this.rpc.pushToast('Saved workbench preferences');
    this.closed.emit();
  }
}
