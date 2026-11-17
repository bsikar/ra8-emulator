import { describe, expect, it, afterEach } from 'vitest';
import { pickBrowserFile } from '../../../src/app/shared/utils/file-picker';

describe('pickBrowserFile', () => {
  const originalPicker = (globalThis as { showOpenFilePicker?: unknown }).showOpenFilePicker;

  afterEach(() => {
    if (originalPicker === undefined) {
      delete (globalThis as { showOpenFilePicker?: unknown }).showOpenFilePicker;
    } else {
      (globalThis as { showOpenFilePicker?: unknown }).showOpenFilePicker = originalPicker;
    }
  });

  it('uses native showOpenFilePicker when available and handles AbortError cleanly', async () => {
    const fakeFile = new File([new Uint8Array([0x7f, 0x45, 0x4c, 0x46])], 'firmware.elf');
    (globalThis as { showOpenFilePicker?: unknown }).showOpenFilePicker = async () => [
      { getFile: async () => fakeFile },
    ];
    const picked = await pickBrowserFile({
      accept: '.elf,.axf',
      description: 'ARM Firmware ELF',
      extensions: ['.elf', '.axf'],
    });
    expect(picked?.name).toBe('firmware.elf');

    (globalThis as { showOpenFilePicker?: unknown }).showOpenFilePicker = async () => {
      const err = new Error('User cancelled');
      err.name = 'AbortError';
      throw err;
    };
    expect(
      await pickBrowserFile({ accept: '.elf', description: 'ELF', extensions: ['.elf'] })
    ).toBeNull();
  });
});
