export interface BrowserFilePickerOptions {
  accept: string;
  description: string;
  extensions: readonly string[];
}

export type PermissionMode = 'read' | 'readwrite';
export type PermissionStateLike = 'granted' | 'denied' | 'prompt';

export interface BrowserFileHandleLike {
  readonly kind?: 'file' | 'directory';
  readonly name: string;
  getFile: () => Promise<File>;
  queryPermission?: (descriptor?: { mode?: PermissionMode }) => Promise<PermissionStateLike>;
  requestPermission?: (descriptor?: { mode?: PermissionMode }) => Promise<PermissionStateLike>;
}

export interface PickedBrowserFile {
  file: File;
  handle: BrowserFileHandleLike | null;
}

interface DataTransferItemWithHandle {
  kind?: string;
  getAsFile?: () => File | null;
  getAsFileSystemHandle?: () => Promise<BrowserFileHandleLike | null>;
}

interface WindowWithOpenPicker {
  showOpenFilePicker?: (opts: {
    multiple?: boolean;
    types?: Array<{
      description?: string;
      accept: Record<string, string[]>;
    }>;
  }) => Promise<BrowserFileHandleLike[]>;
}

function pickViaInputElement(accept: string): Promise<PickedBrowserFile | null> {
  if (typeof document === 'undefined') return Promise.resolve(null);
  return new Promise<PickedBrowserFile | null>((resolve) => {
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = accept;
    input.style.display = 'none';
    let settled = false;
    const finish = (file: File | null): void => {
      if (settled) return;
      settled = true;
      input.remove();
      resolve(file ? { file, handle: null } : null);
    };
    input.addEventListener('change', () => finish(input.files?.[0] ?? null), { once: true });
    input.addEventListener('cancel', () => finish(null), { once: true });
    document.body.appendChild(input);
    input.click();
  });
}

/** Open native OS file dialog and retain FileSystemFileHandle when supported. */
export async function pickBrowserFileWithHandle(opts: BrowserFilePickerOptions): Promise<PickedBrowserFile | null> {
  const host = globalThis as unknown as WindowWithOpenPicker;
  if (typeof host.showOpenFilePicker === 'function') {
    try {
      const handles = await host.showOpenFilePicker({
        multiple: false,
        types: [
          {
            description: opts.description,
            accept: { 'application/octet-stream': [...opts.extensions] },
          },
        ],
      });
      const first = handles[0];
      if (!first) return null;
      return { file: await first.getFile(), handle: first };
    } catch (err) {
      if (err instanceof Error && err.name === 'AbortError') return null;
      throw err;
    }
  }
  return pickViaInputElement(opts.accept);
}

/** Open native OS file dialog via File System Access API when supported, else fallback `<input type="file">`. */
export async function pickBrowserFile(opts: BrowserFilePickerOptions): Promise<File | null> {
  const picked = await pickBrowserFileWithHandle(opts);
  return picked ? picked.file : null;
}

/** Read raw bytes from a File/Blob across browsers and jsdom environments. */
export async function readBlobBytes(blob: Blob): Promise<Uint8Array> {
  if (typeof blob.arrayBuffer === 'function') {
    return new Uint8Array(await blob.arrayBuffer());
  }
  return new Promise<Uint8Array>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const buf = reader.result;
      resolve(buf instanceof ArrayBuffer ? new Uint8Array(buf) : new Uint8Array(0));
    };
    reader.onerror = () => reject(reader.error ?? new Error('Unable to read file bytes'));
    reader.readAsArrayBuffer(blob);
  });
}

/** Verify or request read permission on a retained file handle and return its fresh File. */
export async function readFromFileHandle(handle: BrowserFileHandleLike): Promise<File | null> {
  try {
    if (typeof handle.queryPermission === 'function') {
      let state = await handle.queryPermission({ mode: 'read' });
      if (state === 'prompt' && typeof handle.requestPermission === 'function') {
        state = await handle.requestPermission({ mode: 'read' });
      }
      if (state === 'denied') return null;
    }
    return await handle.getFile();
  } catch (err) {
    if (err instanceof Error && (err.name === 'NotAllowedError' || err.name === 'SecurityError')) {
      return null;
    }
    throw err;
  }
}

/** Extract the dropped file and optional FileSystemFileHandle synchronously before DataTransfer clears. */
export async function extractDroppedFileWithHandle(
  dataTransfer: DataTransfer | null | undefined
): Promise<PickedBrowserFile | null> {
  if (!dataTransfer) return null;
  const fallbackFile = dataTransfer.files?.[0] ?? null;
  const firstItem = dataTransfer.items?.[0] as DataTransferItemWithHandle | undefined;
  const itemFile = firstItem && typeof firstItem.getAsFile === 'function' ? firstItem.getAsFile() : null;
  const syncFile = fallbackFile ?? itemFile;

  if (firstItem && typeof firstItem.getAsFileSystemHandle === 'function') {
    try {
      const handle = await firstItem.getAsFileSystemHandle();
      if (handle && handle.kind !== 'directory' && typeof handle.getFile === 'function') {
        const file = syncFile ?? (await handle.getFile());
        return file ? { file, handle } : null;
      }
    } catch {
      return syncFile ? { file: syncFile, handle: null } : null;
    }
  }
  return syncFile ? { file: syncFile, handle: null } : null;
}
