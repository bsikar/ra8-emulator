import type { Core } from 'ra8-rpc-client';
import type { BrowserFileHandleLike } from '../../shared/utils/file-picker';

export const RECENT_ELF_DB_NAME = 'ra8-recent-elfs-v1';
export const RECENT_ELF_STORE_NAME = 'entries';
export const RECENT_ELF_DB_VERSION = 1;
export const MAX_RECENT_ELFS = 10;

export type RecentElfSourceKind = 'handle' | 'workspace' | 'bytes';

export interface RecentElfEntry {
  id: string;
  fileName: string;
  core: Core;
  sourceKind: RecentElfSourceKind;
  workspacePath: string | null;
  handle: BrowserFileHandleLike | null;
  cachedBytes: Uint8Array | null;
  wsUrl: string;
  openedAtIso: string;
}

export type RecentElfErrorHook = (err: unknown, context: string) => void;

/** True when a file name carries an ARM firmware image extension supported by the loader. */
export function isFirmwareImageFileName(name: string): boolean {
  return /\.(elf|axf|ra8app)$/i.test(name.trim());
}

/** Order recent entries newest-first and cap at `max`. */
export function sortAndTrimRecentEntries(
  items: readonly RecentElfEntry[],
  max = MAX_RECENT_ELFS
): RecentElfEntry[] {
  return [...items]
    .sort((a, b) => {
      const cmp = b.openedAtIso.localeCompare(a.openedAtIso);
      return cmp !== 0 ? cmp : a.id.localeCompare(b.id);
    })
    .slice(0, max);
}

function requestToPromise<T>(req: IDBRequest<T>): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error ?? new Error('IndexedDB request failed'));
  });
}

function transactionDone(tx: IDBTransaction): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error ?? new Error('IndexedDB transaction failed'));
    tx.onabort = () => reject(tx.error ?? new Error('IndexedDB transaction aborted'));
  });
}

function openDatabase(factory: IDBFactory): Promise<IDBDatabase> {
  return new Promise<IDBDatabase>((resolve, reject) => {
    const req = factory.open(RECENT_ELF_DB_NAME, RECENT_ELF_DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(RECENT_ELF_STORE_NAME)) {
        db.createObjectStore(RECENT_ELF_STORE_NAME, { keyPath: 'id' });
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error ?? new Error('Unable to open IndexedDB'));
  });
}

/** IndexedDB-backed repository of the last 10 opened ELFs with in-memory fallback. */
export class RecentElfRepository {
  private readonly fallback = new Map<string, RecentElfEntry>();
  private dbPromise: Promise<IDBDatabase | null> | null = null;

  constructor(
    private readonly idbFactory: IDBFactory | null = typeof indexedDB !== 'undefined' ? indexedDB : null,
    private readonly onError?: RecentElfErrorHook
  ) {}

  public async list(): Promise<RecentElfEntry[]> {
    const db = await this.getDb();
    if (!db) {
      return sortAndTrimRecentEntries([...this.fallback.values()]);
    }
    try {
      const tx = db.transaction(RECENT_ELF_STORE_NAME, 'readonly');
      const items = await requestToPromise(tx.objectStore(RECENT_ELF_STORE_NAME).getAll());
      return sortAndTrimRecentEntries(Array.isArray(items) ? (items as RecentElfEntry[]) : []);
    } catch (err) {
      this.onError?.(err, 'Recent ELF IndexedDB read failed');
      return sortAndTrimRecentEntries([...this.fallback.values()]);
    }
  }

  public async upsert(entry: RecentElfEntry): Promise<RecentElfEntry[]> {
    this.fallback.set(entry.id, entry);
    const trimmedFallback = sortAndTrimRecentEntries([...this.fallback.values()]);
    this.syncFallback(trimmedFallback);

    const db = await this.getDb();
    if (!db) return trimmedFallback;

    try {
      const tx = db.transaction(RECENT_ELF_STORE_NAME, 'readwrite');
      const done = transactionDone(tx);
      const store = tx.objectStore(RECENT_ELF_STORE_NAME);
      this.putEntrySafely(store, entry);
      const all = (await requestToPromise(store.getAll())) as RecentElfEntry[];
      const kept = sortAndTrimRecentEntries(Array.isArray(all) ? all : []);
      const keptIds = new Set(kept.map((item) => item.id));
      for (const candidate of all ?? []) {
        if (!keptIds.has(candidate.id)) {
          store.delete(candidate.id);
        }
      }
      await done;
      return kept;
    } catch (err) {
      this.onError?.(err, 'Recent ELF IndexedDB write failed');
      return trimmedFallback;
    }
  }

  public async remove(id: string): Promise<RecentElfEntry[]> {
    this.fallback.delete(id);
    const db = await this.getDb();
    if (!db) {
      return sortAndTrimRecentEntries([...this.fallback.values()]);
    }
    try {
      const tx = db.transaction(RECENT_ELF_STORE_NAME, 'readwrite');
      const done = transactionDone(tx);
      tx.objectStore(RECENT_ELF_STORE_NAME).delete(id);
      await done;
      return await this.list();
    } catch (err) {
      this.onError?.(err, 'Recent ELF IndexedDB delete failed');
      return sortAndTrimRecentEntries([...this.fallback.values()]);
    }
  }

  public async clear(): Promise<void> {
    this.fallback.clear();
    const db = await this.getDb();
    if (!db) return;
    try {
      const tx = db.transaction(RECENT_ELF_STORE_NAME, 'readwrite');
      const done = transactionDone(tx);
      tx.objectStore(RECENT_ELF_STORE_NAME).clear();
      await done;
    } catch (err) {
      this.onError?.(err, 'Recent ELF IndexedDB clear failed');
    }
  }

  private putEntrySafely(store: IDBObjectStore, entry: RecentElfEntry): void {
    try {
      store.put(entry);
    } catch (err) {
      this.onError?.(err, 'Retaining handle metadata in memory only');
      store.put({ ...entry, handle: null });
    }
  }

  private syncFallback(kept: readonly RecentElfEntry[]): void {
    this.fallback.clear();
    for (const item of kept) this.fallback.set(item.id, item);
  }

  private async getDb(): Promise<IDBDatabase | null> {
    if (!this.idbFactory) return null;
    if (!this.dbPromise) {
      this.dbPromise = openDatabase(this.idbFactory).catch((err) => {
        this.onError?.(err, 'Recent ELF IndexedDB open failed');
        return null;
      });
    }
    return this.dbPromise;
  }
}
