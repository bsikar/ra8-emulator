import { afterEach, describe, expect, it } from 'vitest';
import {
  type BrowserFileHandleLike,
  extractDroppedFileWithHandle,
  pickBrowserFile,
  pickBrowserFileWithHandle,
  readFromFileHandle,
} from '../../../src/app/shared/utils/file-picker';

describe('file-picker utilities', () => {
  const originalPicker = (globalThis as { showOpenFilePicker?: unknown }).showOpenFilePicker;

  afterEach(() => {
    if (originalPicker === undefined) {
      delete (globalThis as { showOpenFilePicker?: unknown }).showOpenFilePicker;
    } else {
      (globalThis as { showOpenFilePicker?: unknown }).showOpenFilePicker = originalPicker;
    }
  });

  it('uses native showOpenFilePicker retaining handle and handles AbortError cleanly', async () => {
    const fakeFile = new File([new Uint8Array([0x7f, 0x45, 0x4c, 0x46])], 'firmware.elf');
    const handle: BrowserFileHandleLike = {
      kind: 'file',
      name: 'firmware.elf',
      getFile: async () => fakeFile,
    };
    (globalThis as { showOpenFilePicker?: unknown }).showOpenFilePicker = async () => [handle];

    const withHandle = await pickBrowserFileWithHandle({
      accept: '.elf,.axf,.ra8app',
      description: 'ARM Firmware ELF',
      extensions: ['.elf', '.axf', '.ra8app'],
    });
    expect(withHandle?.file.name).toBe('firmware.elf');
    expect(withHandle?.handle).toBe(handle);

    const legacy = await pickBrowserFile({
      accept: '.elf,.axf',
      description: 'ARM Firmware ELF',
      extensions: ['.elf', '.axf'],
    });
    expect(legacy?.name).toBe('firmware.elf');

    (globalThis as { showOpenFilePicker?: unknown }).showOpenFilePicker = async () => {
      const err = new Error('User cancelled');
      err.name = 'AbortError';
      throw err;
    };
    expect(
      await pickBrowserFile({ accept: '.elf', description: 'ELF', extensions: ['.elf'] })
    ).toBeNull();
  });

  it('prompts for read permission on retained file handle when needed and respects denied permission', async () => {
    const fresh = new File([new Uint8Array([1, 2, 3])], 'rebuilt.elf');
    let requested = false;
    const promptedHandle: BrowserFileHandleLike = {
      name: 'rebuilt.elf',
      queryPermission: async () => 'prompt',
      requestPermission: async () => {
        requested = true;
        return 'granted';
      },
      getFile: async () => fresh,
    };
    const file = await readFromFileHandle(promptedHandle);
    expect(requested).toBe(true);
    expect(file?.name).toBe('rebuilt.elf');

    const deniedHandle: BrowserFileHandleLike = {
      name: 'denied.elf',
      queryPermission: async () => 'denied',
      getFile: async () => fresh,
    };
    expect(await readFromFileHandle(deniedHandle)).toBeNull();
  });

  it('extracts dropped files with optional FileSystemFileHandle before async resolution', async () => {
    const droppedFile = new File([new Uint8Array([0x7f, 0x45, 0x4c, 0x46])], 'dropped.elf');
    const droppedHandle: BrowserFileHandleLike = {
      kind: 'file',
      name: 'dropped.elf',
      getFile: async () => droppedFile,
    };
    const dtWithHandle = {
      files: [droppedFile] as unknown as FileList,
      items: [
        {
          kind: 'file',
          getAsFile: () => droppedFile,
          getAsFileSystemHandle: async () => droppedHandle,
        },
      ] as unknown as DataTransferItemList,
    } as unknown as DataTransfer;

    const extracted = await extractDroppedFileWithHandle(dtWithHandle);
    expect(extracted?.file.name).toBe('dropped.elf');
    expect(extracted?.handle).toBe(droppedHandle);

    const dtFallback = {
      files: [droppedFile] as unknown as FileList,
      items: [] as unknown as DataTransferItemList,
    } as unknown as DataTransfer;
    const fallback = await extractDroppedFileWithHandle(dtFallback);
    expect(fallback?.file.name).toBe('dropped.elf');
    expect(fallback?.handle).toBeNull();
  });
});
