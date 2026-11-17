/**
 * Root Angular Signal store coordinating Vim modal editing state, persisted enablement,
 * buffer synchronization, and `:ex` command handlers.
 */

import { Injectable, computed, signal } from '@angular/core';
import { stepVimEngine } from './vim-engine';
import { clampCursor, computeVisualSelection } from './vim-motions';
import {
  type ExCommand,
  type VimBufferState,
  type VimCursor,
  type VimKeyInput,
  type VimKeyResult,
  type VimMode,
  type VimSelection,
  createVimBufferState,
  parseExCommand,
} from './vim-types';

const VIM_ENABLED_STORAGE_KEY = 'ra8.vim.enabled.v1';

export type ExCommandHandler = (command: ExCommand, raw: string) => void | boolean | Promise<void | boolean>;

export interface VimHandleKeyOptions {
  allowColonWhenDisabled?: boolean;
}

@Injectable({ providedIn: 'root' })
export class VimStore {
  private readonly handlers = new Map<string, Set<ExCommandHandler>>();

  public readonly enabled = signal<boolean>(this.loadEnabledPreference());
  public readonly bufferState = signal<VimBufferState>(createVimBufferState({ readOnly: true }));
  public readonly lastMessage = signal<string>('');
  public readonly lastMessageTone = signal<'neutral' | 'fault'>('neutral');

  public readonly mode = computed<VimMode>(() => this.bufferState().mode);
  public readonly pendingKeys = computed<string>(() => {
    const s = this.bufferState();
    return `${s.countBuffer}${s.pendingOperator}`;
  });
  public readonly commandBuffer = computed<string>(() => this.bufferState().commandBuffer);
  public readonly searchPromptActive = computed<boolean>(() => this.bufferState().searchPromptActive);
  public readonly searchBuffer = computed<string>(() => this.bufferState().searchBuffer);
  public readonly cursor = computed<VimCursor>(() => this.bufferState().cursor);
  public readonly lines = computed<string[]>(() => this.bufferState().lines);
  public readonly selection = computed<VimSelection | null>(() => {
    const s = this.bufferState();
    return computeVisualSelection(s.mode, s.visualAnchor, s.cursor, s.lines);
  });

  public readonly statusLabel = computed<string>(() => {
    if (!this.enabled()) return 'VIM: OFF';
    const s = this.bufferState();
    if (s.mode === 'command') return `VIM: :${s.commandBuffer}`;
    if (s.searchPromptActive) return `VIM: ${s.searchDirection === 'forward' ? '/' : '?'}${s.searchBuffer}`;
    if (s.mode === 'visual-line') return 'VIM: V-LINE';
    return `VIM: ${s.mode.toUpperCase()}`;
  });

  /** Enables or disables Vim mode and persists the setting in `localStorage`. */
  public setEnabled(next: boolean): void {
    this.enabled.set(next);
    this.saveEnabledPreference(next);
    if (!next) {
      this.bufferState.update((s) => ({
        ...s,
        mode: 'normal',
        countBuffer: '',
        pendingOperator: '',
        searchPromptActive: false,
        searchBuffer: '',
        commandBuffer: '',
        visualAnchor: null,
      }));
    }
    this.setMessage(next ? 'Vim mode enabled' : 'Vim mode disabled', 'neutral');
  }

  /** Toggles Vim mode on/off and returns the new state. */
  public toggleEnabled(): boolean {
    const next = !this.enabled();
    this.setEnabled(next);
    return next;
  }

  /** Binds a buffer of lines (e.g. workspace list or code viewer) to the Vim engine. */
  public bindBuffer(options: {
    lines: readonly string[];
    readOnly?: boolean;
    viewportHeight?: number;
    cursor?: VimCursor;
  }): void {
    this.bufferState.set(createVimBufferState(options));
  }

  /** Updates only the lines in the active Vim buffer while preserving cursor and marks. */
  public updateLines(lines: readonly string[], readOnly?: boolean): void {
    const safeLines = lines.length > 0 ? [...lines] : [''];
    this.bufferState.update((prev) => ({
      ...prev,
      lines: safeLines,
      readOnly: readOnly ?? prev.readOnly,
      cursor: clampCursor(safeLines, prev.cursor, prev.mode === 'insert'),
    }));
  }

  /** Opens inline `:ex` command mode directly, even if called from a status-bar button. */
  public openCommandMode(initialCommand = ''): void {
    this.bufferState.update((s) => ({
      ...s,
      mode: 'command',
      commandBuffer: initialCommand,
      countBuffer: '',
      pendingOperator: '',
      searchPromptActive: false,
    }));
  }

  /** Registers a handler for an Ex command kind (e.g. `'edit'`, `'extensions'`, `'*'`) or custom command name. */
  public registerExHandler(target: string, handler: ExCommandHandler): () => void {
    const key = target.trim().toLowerCase();
    let bucket = this.handlers.get(key);
    if (!bucket) {
      bucket = new Set();
      this.handlers.set(key, bucket);
    }
    bucket.add(handler);
    return () => {
      const existing = this.handlers.get(key);
      if (!existing) return;
      existing.delete(handler);
      if (existing.size === 0) this.handlers.delete(key);
    };
  }

  /** Processes a keyboard event through the Vim state machine when active. */
  public handleKeyDown(input: VimKeyInput, options: VimHandleKeyOptions = {}): VimKeyResult {
    const cur = this.bufferState();
    const allowColon = Boolean(options.allowColonWhenDisabled) && input.key === ':' && cur.mode === 'normal';
    if (!this.enabled() && cur.mode !== 'command' && !allowColon) {
      return { handled: false, state: cur, actions: [{ type: 'none' }], selection: null };
    }
    const result = stepVimEngine(cur, input);
    if (result.handled) {
      this.bufferState.set(result.state);
      this.applyResultActions(result);
    }
    return result;
  }

  /** Parses and executes a raw `:ex` command string against built-ins and registered handlers. */
  public async executeExCommand(rawInput: string): Promise<boolean> {
    const parsed = parseExCommand(rawInput);
    if (!parsed) return false;
    return this.dispatchExCommand(parsed, rawInput.trim().replace(/^:+/, ''));
  }

  private applyResultActions(result: VimKeyResult): void {
    for (const action of result.actions) {
      if (action.type === 'message') {
        this.setMessage(action.text, action.tone);
      } else if (action.type === 'ex-execute') {
        void this.dispatchExCommand(action.command, action.raw);
      }
    }
  }

  private async dispatchExCommand(command: ExCommand, raw: string): Promise<boolean> {
    if (command.kind === 'vim-toggle') {
      if (command.enabled === null) this.toggleEnabled();
      else this.setEnabled(command.enabled);
      return true;
    }
    if (command.kind === 'goto-line') {
      this.bufferState.update((s) =>
        stepVimEngine({ ...s, countBuffer: String(command.line) }, { key: 'G' }).state
      );
    }

    const targets = new Set<string>([command.kind]);
    if (command.kind === 'custom') targets.add(command.name.toLowerCase());
    targets.add('*');

    let invoked = false;
    for (const target of targets) {
      const set = this.handlers.get(target);
      if (!set) continue;
      for (const handler of set) {
        const res = await handler(command, raw);
        if (res !== false) invoked = true;
      }
    }

    if (!invoked && command.kind !== 'goto-line') {
      this.setMessage(`Not an editor command: ${raw}`, 'fault');
    }
    return invoked || command.kind === 'goto-line';
  }

  private setMessage(text: string, tone: 'neutral' | 'fault'): void {
    this.lastMessage.set(text);
    this.lastMessageTone.set(tone);
  }

  private loadEnabledPreference(): boolean {
    if (typeof localStorage === 'undefined') return false;
    try {
      return localStorage.getItem(VIM_ENABLED_STORAGE_KEY) === 'true';
    } catch (err) {
      this.lastMessage.set(`Vim preference read error: ${err instanceof Error ? err.message : String(err)}`);
      return false;
    }
  }

  private saveEnabledPreference(value: boolean): void {
    if (typeof localStorage === 'undefined') return;
    try {
      localStorage.setItem(VIM_ENABLED_STORAGE_KEY, value ? 'true' : 'false');
    } catch (err) {
      this.lastMessage.set(`Vim preference write error: ${err instanceof Error ? err.message : String(err)}`);
    }
  }
}
