import { describe, expect, it } from 'vitest';
import { Core } from 'ra8-rpc-client';
import {
  MAX_RECENT_ELFS,
  RECENT_ELF_STORE_NAME,
  type RecentElfEntry,
  RecentElfRepository,
  isFirmwareImageFileName,
} from '../../../src/app/core/stores/recent-elf-db';

function makeIdbReq<T>(run: () => T): IDBRequest<T> {
  const req = {
    result: undefined as unknown as T,
    error: null as DOMException | null,
    onsuccess: null as ((ev: Event) => unknown) | null,
    onerror: null as ((ev: Event) => unknown) | null,
  };
  queueMicrotask(() => {
    try {
      req.result = run();
      req.onsuccess?.({} as Event);
    } catch (err) {
      req.error = err as DOMException;
      req.onerror?.({} as Event);
    }
  });
  return req as unknown as IDBRequest<T>;
}

function makeMockIndexedDb(): { factory: IDBFactory; storeMap: Map<string, RecentElfEntry> } {
  const storeMap = new Map<string, RecentElfEntry>();

  const makeStore = (): IDBObjectStore =>
    ({
      put: (val: RecentElfEntry) => {
        storeMap.set(val.id, val);
        return makeIdbReq(() => val.id);
      },
      delete: (key: string) => {
        storeMap.delete(key);
        return makeIdbReq(() => undefined);
      },
      clear: () => {
        storeMap.clear();
        return makeIdbReq(() => undefined);
      },
      getAll: () => makeIdbReq(() => [...storeMap.values()]),
    }) as unknown as IDBObjectStore;

  const makeDb = (): IDBDatabase =>
    ({
      objectStoreNames: { contains: () => false } as unknown as DOMStringList,
      createObjectStore: (name: string) => {
        expect(name).toBe(RECENT_ELF_STORE_NAME);
        return {} as IDBObjectStore;
      },
      transaction: (_name: string, _mode: string) => {
        const tx = {
          error: null,
          oncomplete: null as (() => void) | null,
          onerror: null as (() => void) | null,
          onabort: null as (() => void) | null,
          objectStore: () => makeStore(),
        };
        setTimeout(() => tx.oncomplete?.(), 0);
        return tx as unknown as IDBTransaction;
      },
    }) as unknown as IDBDatabase;

  const factory = {
    open: () => {
      const openReq = {
        result: makeDb(),
        error: null,
        onupgradeneeded: null as ((ev: IDBVersionChangeEvent) => unknown) | null,
        onsuccess: null as ((ev: Event) => unknown) | null,
        onerror: null as ((ev: Event) => unknown) | null,
      };
      queueMicrotask(() => {
        openReq.onupgradeneeded?.({} as IDBVersionChangeEvent);
        openReq.onsuccess?.({} as Event);
      });
      return openReq as unknown as IDBOpenDBRequest;
    },
  } as unknown as IDBFactory;

  return { factory, storeMap };
}

function makeEntry(index: number): RecentElfEntry {
  return {
    id: `elf-${index}`,
    fileName: `app_${index}.elf`,
    core: Core.Cpu0,
    sourceKind: 'handle',
    workspacePath: null,
    handle: {
      kind: 'file',
      name: `app_${index}.elf`,
      getFile: async () => new File([new Uint8Array([index])], `app_${index}.elf`),
    },
    cachedBytes: new Uint8Array([index]),
    wsUrl: 'ws://127.0.0.1:4567',
    openedAtIso: `2026-11-21T10:${String(index).padStart(2, '0')}:00.000Z`,
  };
}

describe('RecentElfRepository', () => {
  it('detects supported firmware extensions (.elf, .axf, .ra8app)', () => {
    expect(isFirmwareImageFileName('blink.elf')).toBe(true);
    expect(isFirmwareImageFileName('bootloader.axf')).toBe(true);
    expect(isFirmwareImageFileName('motor_ctrl.ra8app')).toBe(true);
    expect(isFirmwareImageFileName('ek_ra8d2.board')).toBe(false);
    expect(isFirmwareImageFileName('bundle.tar.gz')).toBe(false);
  });

  it('persists entries in IndexedDB, trims to last 10 newest-first, removes, and clears', async () => {
    const { factory, storeMap } = makeMockIndexedDb();
    const repo = new RecentElfRepository(factory);

    for (let i = 1; i <= 12; i++) {
      await repo.upsert(makeEntry(i));
    }

    const listed = await repo.list();
    expect(listed.length).toBe(MAX_RECENT_ELFS);
    expect(storeMap.size).toBe(MAX_RECENT_ELFS);
    expect(listed[0]?.fileName).toBe('app_12.elf');
    expect(listed[9]?.fileName).toBe('app_3.elf');
    expect(listed[0]?.handle?.name).toBe('app_12.elf');

    const afterRemove = await repo.remove('elf-12');
    expect(afterRemove.length).toBe(9);
    expect(afterRemove[0]?.fileName).toBe('app_11.elf');

    await repo.clear();
    expect(await repo.list()).toEqual([]);
  });

  it('falls back cleanly to bounded in-memory storage when indexedDB is unavailable', async () => {
    const repo = new RecentElfRepository(null);
    for (let i = 1; i <= 12; i++) {
      await repo.upsert(makeEntry(i));
    }
    const items = await repo.list();
    expect(items.length).toBe(10);
    expect(items[0]?.id).toBe('elf-12');
    expect(items[9]?.id).toBe('elf-3');
  });
});
