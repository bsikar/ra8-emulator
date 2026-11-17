/**
 * Core data structures, mode definitions, and `:ex` command parsing for the
 * Vim modal keymap engine.
 */

export type VimMode = 'normal' | 'insert' | 'visual' | 'visual-line' | 'command';

export type VimSearchDirection = 'forward' | 'backward';

export type VimPendingOperator = '' | 'g' | 'd' | 'y' | 'm' | "'";

export interface VimCursor {
  line: number;
  col: number;
}

export interface VimSelection {
  start: VimCursor;
  end: VimCursor;
  linewise: boolean;
}

export interface VimMark {
  line: number;
  col: number;
}

export interface VimYankRegister {
  text: string;
  linewise: boolean;
}

export interface VimKeyInput {
  key: string;
  ctrlKey?: boolean;
  shiftKey?: boolean;
  altKey?: boolean;
  metaKey?: boolean;
}

export interface VimBufferState {
  lines: string[];
  cursor: VimCursor;
  mode: VimMode;
  readOnly: boolean;
  countBuffer: string;
  pendingOperator: VimPendingOperator;
  searchPromptActive: boolean;
  searchDirection: VimSearchDirection;
  searchBuffer: string;
  lastSearchPattern: string;
  lastSearchDirection: VimSearchDirection;
  commandBuffer: string;
  visualAnchor: VimCursor | null;
  marks: Record<string, VimMark>;
  yankRegister: VimYankRegister | null;
  dirty: boolean;
  viewportHeight: number;
}

export type ExCommand =
  | { kind: 'write'; force: boolean }
  | { kind: 'quit'; force: boolean }
  | { kind: 'write-quit' }
  | { kind: 'edit'; file: string }
  | { kind: 'goto-line'; line: number }
  | { kind: 'goto-address'; address: number }
  | { kind: 'vim-toggle'; enabled: boolean | null }
  | { kind: 'extensions' }
  | { kind: 'help'; topic?: string }
  | { kind: 'connect'; url: string }
  | { kind: 'custom'; raw: string; name: string; args: string[] };

export type VimAction =
  | { type: 'none' }
  | { type: 'moved'; cursor: VimCursor }
  | { type: 'mode-changed'; mode: VimMode }
  | { type: 'buffer-changed'; lines: string[]; cursor: VimCursor }
  | { type: 'search-match'; cursor: VimCursor; pattern: string; found: boolean }
  | { type: 'ex-execute'; command: ExCommand; raw: string }
  | { type: 'message'; text: string; tone: 'neutral' | 'fault' };

export interface VimKeyResult {
  handled: boolean;
  state: VimBufferState;
  actions: VimAction[];
  selection: VimSelection | null;
}

export interface CreateVimStateOptions {
  lines?: readonly string[];
  readOnly?: boolean;
  viewportHeight?: number;
  cursor?: VimCursor;
}

/** Creates an initialized immutable Vim buffer state with safe bounds. */
export function createVimBufferState(options: CreateVimStateOptions = {}): VimBufferState {
  const lines = options.lines && options.lines.length > 0 ? [...options.lines] : [''];
  const rawLine = options.cursor?.line ?? 0;
  const line = Math.max(0, Math.min(lines.length - 1, rawLine));
  const lineLen = (lines[line] ?? '').length;
  const col = Math.max(0, Math.min(Math.max(0, lineLen - 1), options.cursor?.col ?? 0));
  return {
    lines,
    cursor: { line, col },
    mode: 'normal',
    readOnly: options.readOnly ?? false,
    countBuffer: '',
    pendingOperator: '',
    searchPromptActive: false,
    searchDirection: 'forward',
    searchBuffer: '',
    lastSearchPattern: '',
    lastSearchDirection: 'forward',
    commandBuffer: '',
    visualAnchor: null,
    marks: {},
    yankRegister: null,
    dirty: false,
    viewportHeight: Math.max(2, options.viewportHeight ?? 20),
  };
}

/** Parses a `:ex` command line string (with or without leading `:`). */
export function parseExCommand(rawInput: string): ExCommand | null {
  const clean = rawInput.trim().replace(/^:+/, '').trim();
  if (!clean) return null;

  if (/^0x[0-9a-fA-F_]+$/i.test(clean)) {
    const parsed = Number.parseInt(clean.slice(2).replace(/_/g, ''), 16);
    if (Number.isFinite(parsed)) {
      return { kind: 'goto-address', address: parsed >>> 0 };
    }
  }
  if (/^\d+$/.test(clean)) {
    return { kind: 'goto-line', line: Math.max(1, Number.parseInt(clean, 10)) };
  }

  const parts = clean.split(/\s+/);
  const name = (parts[0] ?? '').toLowerCase();
  const args = parts.slice(1);
  return mapNamedExCommand(clean, name, args);
}

function mapNamedExCommand(raw: string, name: string, args: string[]): ExCommand {
  if (name === 'w' || name === 'write' || name === 'w!') {
    return { kind: 'write', force: name.endsWith('!') };
  }
  if (name === 'q' || name === 'quit' || name === 'q!') {
    return { kind: 'quit', force: name.endsWith('!') };
  }
  if (name === 'wq' || name === 'x') {
    return { kind: 'write-quit' };
  }
  if (name === 'e' || name === 'edit') {
    return { kind: 'edit', file: args.join(' ').trim() };
  }
  if (name === 'ext' || name === 'extensions') {
    return { kind: 'extensions' };
  }
  if (name === 'h' || name === 'help') {
    const topic = args.join(' ').trim();
    return topic ? { kind: 'help', topic } : { kind: 'help' };
  }
  if (name === 'connect') {
    return { kind: 'connect', url: args.join(' ').trim() };
  }
  if (name === 'vim') {
    const arg = (args[0] ?? '').toLowerCase();
    if (arg === 'on' || arg === 'enable' || arg === '1') return { kind: 'vim-toggle', enabled: true };
    if (arg === 'off' || name === 'vim' && (arg === 'disable' || arg === '0')) return { kind: 'vim-toggle', enabled: false };
    return { kind: 'vim-toggle', enabled: null };
  }
  return { kind: 'custom', raw, name, args };
}
