/**
 * Strict manual manifest schema validation (zero `any`) and starter example
 * definition for sandboxed Web Worker extensions.
 */

export interface ExtensionCommandContribution {
  command: string;
  title: string;
  category?: string;
}

export interface ExtensionKeybindingContribution {
  command: string;
  key: string;
  when?: string;
}

export interface ExtensionPanelContribution {
  id: string;
  title: string;
  location?: 'sidebar' | 'panel' | 'drawer';
}

export interface ExtensionContributes {
  commands: ExtensionCommandContribution[];
  keybindings: ExtensionKeybindingContribution[];
  panels: ExtensionPanelContribution[];
}

export interface ExtensionManifest {
  id: string;
  name: string;
  displayName: string;
  version: string;
  description: string;
  publisher: string;
  activationEvents: string[];
  contributes: ExtensionContributes;
  mainSource: string;
}

export type ManifestValidationResult =
  | { ok: true; manifest: ExtensionManifest }
  | { ok: false; errors: string[] };

const IDENT_SEGMENT_RE = /^[a-z0-9][a-z0-9-]*$/i;
const FULL_ID_RE = /^[a-z0-9][a-z0-9-]*\.[a-z0-9][a-z0-9-]*$/i;
const SEMVER_RE = /^\d+\.\d+\.\d+(?:-[a-z0-9.-]+)?$/i;
const PANEL_LOCATIONS = new Set(['sidebar', 'panel', 'drawer']);

/** Explicit starter manifest used ONLY when the user triggers "+ Load Example Extension". */
export const STARTER_EXTENSION_MANIFEST: ExtensionManifest = {
  id: 'ra8.target-inspector',
  name: 'target-inspector',
  publisher: 'ra8',
  displayName: 'Target Register Snapshot',
  version: '0.1.0',
  description: 'Reads live execution state and CPU0 registers inside an isolated Web Worker.',
  activationEvents: ['onStartupFinished'],
  contributes: {
    commands: [
      {
        command: 'ra8.targetInspector.snapshot',
        title: 'Capture Target Snapshot',
        category: 'Extensions',
      },
    ],
    keybindings: [
      {
        command: 'ra8.targetInspector.snapshot',
        key: 'Ctrl+Alt+S',
      },
    ],
    panels: [
      {
        id: 'ra8.targetInspector.panel',
        title: 'Target Snapshot',
        location: 'panel',
      },
    ],
  },
  mainSource: [
    'async function activate() {',
    "  await ra8.commands.registerCommand('ra8.targetInspector.snapshot', async () => {",
    '    const exec = await ra8.debug.getExecutionState();',
    '    const regs = await ra8.debug.readRegisters(0);',
    '    const pc = typeof regs.pc === "number" ? "0x" + (regs.pc >>> 0).toString(16) : "uninitialized";',
    '    const summary = `Core ${exec.activeCore} · ${exec.executionStatus} · PC ${pc}`;',
    "    await ra8.views.postPanelState('ra8.targetInspector.panel', { summary, exec });",
    '    await ra8.window.showInformationMessage(summary);',
    '    return { summary, pc };',
    '  });',
    '}',
  ].join('\n'),
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function readNonEmptyString(
  obj: Record<string, unknown>,
  field: string,
  errors: string[],
  pattern?: RegExp
): string {
  const value = obj[field];
  if (typeof value !== 'string' || value.trim().length === 0) {
    errors.push(`Field "${field}" must be a non-empty string`);
    return '';
  }
  const trimmed = value.trim();
  if (pattern && !pattern.test(trimmed)) {
    errors.push(`Field "${field}" has invalid format: "${trimmed}"`);
  }
  return trimmed;
}

function readOptionalString(obj: Record<string, unknown>, field: string, errors: string[]): string | undefined {
  const value = obj[field];
  if (value === undefined) return undefined;
  if (typeof value !== 'string') {
    errors.push(`Field "${field}" must be a string when provided`);
    return undefined;
  }
  return value.trim();
}

function validateActivationEvents(raw: unknown, errors: string[]): string[] {
  if (!Array.isArray(raw)) {
    errors.push('Field "activationEvents" must be an array of strings');
    return [];
  }
  const events: string[] = [];
  for (let i = 0; i < raw.length; i++) {
    const entry = raw[i];
    if (typeof entry !== 'string' || entry.trim().length === 0) {
      errors.push(`activationEvents[${i}] must be a non-empty string`);
    } else {
      events.push(entry.trim());
    }
  }
  return events;
}

function validateCommandsList(raw: unknown, errors: string[]): ExtensionCommandContribution[] {
  if (raw === undefined) return [];
  if (!Array.isArray(raw)) {
    errors.push('contributes.commands must be an array');
    return [];
  }
  const out: ExtensionCommandContribution[] = [];
  for (let i = 0; i < raw.length; i++) {
    const item = raw[i];
    if (!isRecord(item)) {
      errors.push(`contributes.commands[${i}] must be an object`);
      continue;
    }
    const command = readNonEmptyString(item, 'command', errors);
    const title = readNonEmptyString(item, 'title', errors);
    const category = readOptionalString(item, 'category', errors);
    if (command && title) {
      out.push(category ? { command, title, category } : { command, title });
    }
  }
  return out;
}

function validateKeybindingsList(raw: unknown, errors: string[]): ExtensionKeybindingContribution[] {
  if (raw === undefined) return [];
  if (!Array.isArray(raw)) {
    errors.push('contributes.keybindings must be an array');
    return [];
  }
  const out: ExtensionKeybindingContribution[] = [];
  for (let i = 0; i < raw.length; i++) {
    const item = raw[i];
    if (!isRecord(item)) {
      errors.push(`contributes.keybindings[${i}] must be an object`);
      continue;
    }
    const command = readNonEmptyString(item, 'command', errors);
    const key = readNonEmptyString(item, 'key', errors);
    const when = readOptionalString(item, 'when', errors);
    if (command && key) {
      out.push(when ? { command, key, when } : { command, key });
    }
  }
  return out;
}

function validatePanelsList(raw: unknown, errors: string[]): ExtensionPanelContribution[] {
  if (raw === undefined) return [];
  if (!Array.isArray(raw)) {
    errors.push('contributes.panels must be an array');
    return [];
  }
  const out: ExtensionPanelContribution[] = [];
  for (let i = 0; i < raw.length; i++) {
    const item = raw[i];
    if (!isRecord(item)) {
      errors.push(`contributes.panels[${i}] must be an object`);
      continue;
    }
    const id = readNonEmptyString(item, 'id', errors);
    const title = readNonEmptyString(item, 'title', errors);
    const loc = readOptionalString(item, 'location', errors);
    if (loc && !PANEL_LOCATIONS.has(loc)) {
      errors.push(`contributes.panels[${i}].location must be sidebar, panel, or drawer`);
      continue;
    }
    if (id && title) {
      const typedLoc = loc as ExtensionPanelContribution['location'] | undefined;
      out.push(typedLoc ? { id, title, location: typedLoc } : { id, title });
    }
  }
  return out;
}

function validateContributes(raw: unknown, errors: string[]): ExtensionContributes {
  if (raw === undefined) return { commands: [], keybindings: [], panels: [] };
  if (!isRecord(raw)) {
    errors.push('Field "contributes" must be an object');
    return { commands: [], keybindings: [], panels: [] };
  }
  return {
    commands: validateCommandsList(raw['commands'], errors),
    keybindings: validateKeybindingsList(raw['keybindings'], errors),
    panels: validatePanelsList(raw['panels'], errors),
  };
}

/** Validates an unknown payload against the strict extension manifest contract. */
export function validateExtensionManifest(raw: unknown): ManifestValidationResult {
  if (!isRecord(raw)) {
    return { ok: false, errors: ['Extension manifest must be a JSON object'] };
  }

  const errors: string[] = [];
  const publisher = readNonEmptyString(raw, 'publisher', errors, IDENT_SEGMENT_RE);
  const name = readNonEmptyString(raw, 'name', errors, IDENT_SEGMENT_RE);
  const id = readNonEmptyString(raw, 'id', errors, FULL_ID_RE);
  if (publisher && name && id && id.toLowerCase() !== `${publisher}.${name}`.toLowerCase()) {
    errors.push(`Field "id" ("${id}") must equal "${publisher}.${name}"`);
  }

  const displayName = readNonEmptyString(raw, 'displayName', errors);
  const version = readNonEmptyString(raw, 'version', errors, SEMVER_RE);
  const description = typeof raw['description'] === 'string' ? raw['description'] : '';
  if (typeof raw['description'] !== 'string') {
    errors.push('Field "description" must be a string');
  }
  const activationEvents = validateActivationEvents(raw['activationEvents'], errors);
  const contributes = validateContributes(raw['contributes'], errors);
  const mainSource = readNonEmptyString(raw, 'mainSource', errors);

  if (errors.length > 0) return { ok: false, errors };

  return {
    ok: true,
    manifest: {
      id,
      name,
      displayName,
      version,
      description,
      publisher,
      activationEvents,
      contributes,
      mainSource,
    },
  };
}

/** Parses raw JSON text and validates the resulting extension manifest. */
export function parseExtensionManifestJson(rawJson: string): ManifestValidationResult {
  try {
    const parsed: unknown = JSON.parse(rawJson);
    return validateExtensionManifest(parsed);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return { ok: false, errors: [`Invalid JSON manifest: ${message}`] };
  }
}
