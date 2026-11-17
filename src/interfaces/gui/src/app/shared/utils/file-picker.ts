export interface BrowserFilePickerOptions {
  accept: string;
  description: string;
  extensions: readonly string[];
}

interface PickerHandle {
  getFile: () => Promise<File>;
}

interface WindowWithOpenPicker {
  showOpenFilePicker?: (opts: {
    multiple?: boolean;
    types?: Array<{
      description?: string;
      accept: Record<string, string[]>;
    }>;
  }) => Promise<PickerHandle[]>;
}

/** Open native OS file dialog via File System Access API when supported, else fallback `<input type="file">`. */
export async function pickBrowserFile(opts: BrowserFilePickerOptions): Promise<File | null> {
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
      return first ? await first.getFile() : null;
    } catch (err) {
      if (err instanceof Error && err.name === 'AbortError') return null;
      throw err;
    }
  }
  if (typeof document === 'undefined') return null;
  return new Promise<File | null>((resolve) => {
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = opts.accept;
    input.style.display = 'none';
    let settled = false;
    const finish = (file: File | null): void => {
      if (settled) return;
      settled = true;
      input.remove();
      resolve(file);
    };
    input.addEventListener('change', () => finish(input.files?.[0] ?? null), { once: true });
    input.addEventListener('cancel', () => finish(null), { once: true });
    document.body.appendChild(input);
    input.click();
  });
}
