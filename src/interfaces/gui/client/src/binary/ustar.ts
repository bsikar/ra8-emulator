/**
 * Bounded POSIX USTAR / Gzip bundle header reader matching `src/snapshot/bundle/`.
 * Used for previewing staged `.tar` / `.tar.gz` bundle manifests locally;
 * full session export/import streams through RPC `artifacts` (`0x0180..0x0185`).
 */

const TAR_BLOCK = 512;
const DEFAULT_MAX_ENTRIES = 4096;
const MAX_MANIFEST_BYTES = 8192;

export interface UstarEntry {
  path: string;
  size: number;
  dataOffset: number;
  data: Uint8Array;
}

export interface BundleManifestElf {
  name: string;
  identity: string;
  size: number;
}

export interface BundleManifest {
  format: string;
  version: number;
  snapshotVersion: number;
  board: string;
  elf0: BundleManifestElf;
  elf1: BundleManifestElf | null;
  recording: boolean;
}

export interface BundlePreview {
  compressed: boolean;
  totalTarBytes: number;
  entries: Array<{ path: string; size: number; dataOffset: number }>;
  manifest: BundleManifest | null;
}

export function isGzipBuffer(bytes: Uint8Array): boolean {
  return bytes.length >= 2 && bytes[0] === 0x1f && bytes[1] === 0x8b;
}

function assertSafeArchivePath(entryPath: string): string {
  const normalized = entryPath.trim();
  if (
    !normalized ||
    normalized.startsWith("/") ||
    normalized.startsWith("\\") ||
    normalized.includes("\0") ||
    normalized.includes("\\")
  ) {
    throw new Error(`Unsafe archive entry path: ${entryPath}`);
  }
  const parts = normalized.split("/");
  if (parts.some((p) => p === "" || p === "." || p === "..")) {
    throw new Error(`Unsafe archive path traversal in entry: ${entryPath}`);
  }
  return normalized;
}

function readCString(buf: Uint8Array, offset: number, maxLen: number): string {
  let end = offset;
  const limit = Math.min(buf.length, offset + maxLen);
  while (end < limit && buf[end] !== 0) {
    end++;
  }
  return new TextDecoder().decode(buf.subarray(offset, end));
}

function isZeroBlock(buf: Uint8Array, offset: number): boolean {
  for (let i = 0; i < TAR_BLOCK; i++) {
    if ((buf[offset + i] ?? 0) !== 0) return false;
  }
  return true;
}

function verifyUstarHeader(header: Uint8Array): void {
  const raw = readCString(header, 148, 8).trim();
  const expected = Number.parseInt(raw, 8);
  if (!Number.isFinite(expected)) {
    throw new Error("Invalid TAR header checksum");
  }
  let actual = 0;
  for (let i = 0; i < TAR_BLOCK; i++) {
    actual += i >= 148 && i < 156 ? 0x20 : (header[i] ?? 0);
  }
  if (actual !== expected) {
    throw new Error(`Corrupt TAR header checksum (expected ${expected}, got ${actual})`);
  }

  const magic = readCString(header, 257, 6);
  const version = new TextDecoder().decode(header.subarray(263, 265));
  if (magic !== "ustar" || version !== "00") {
    throw new Error(`Unsupported TAR format: magic=${magic}`);
  }

  const typeflag = header[156] ?? 0;
  if (typeflag !== 0x30 && typeflag !== 0) {
    throw new Error(`Unsupported USTAR entry type: ${typeflag}`);
  }
}

async function gunzipBuffer(gz: Uint8Array): Promise<Uint8Array> {
  if (typeof DecompressionStream === "undefined") {
    throw new Error("DecompressionStream('gzip') is not available in this runtime");
  }
  const copy = new Uint8Array(gz.byteLength);
  copy.set(gz);
  const stream = new Blob([copy]).stream().pipeThrough(new DecompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

/** Walk and validate regular USTAR entries in an uncompressed `.tar` buffer. */
export function parseUstarEntries(
  tarBytes: Uint8Array,
  maxEntries = DEFAULT_MAX_ENTRIES
): UstarEntry[] {
  if (tarBytes.length < TAR_BLOCK) {
    throw new Error("Invalid TAR archive: truncated below 512-byte USTAR header block");
  }
  const entries: UstarEntry[] = [];
  let offset = 0;

  while (offset + TAR_BLOCK <= tarBytes.length) {
    if (isZeroBlock(tarBytes, offset)) {
      break;
    }
    if (entries.length >= maxEntries) {
      throw new Error(`TAR archive exceeds ${maxEntries} entry cap`);
    }
    const header = tarBytes.subarray(offset, offset + TAR_BLOCK);
    verifyUstarHeader(header);

    const namePart = readCString(header, 0, 100);
    const prefixPart = readCString(header, 345, 155);
    const fullName = prefixPart ? `${prefixPart}/${namePart}` : namePart;
    const safePath = assertSafeArchivePath(fullName);

    const sizeOctal = readCString(header, 124, 12).trim();
    const size = Number.parseInt(sizeOctal || "0", 8);
    if (!Number.isFinite(size) || size < 0) {
      throw new Error(`Invalid TAR entry size for ${safePath}`);
    }

    const dataOffset = offset + TAR_BLOCK;
    if (dataOffset + size > tarBytes.length) {
      throw new Error(`Truncated TAR entry payload for ${safePath}`);
    }

    entries.push({
      path: safePath,
      size,
      dataOffset,
      data: tarBytes.subarray(dataOffset, dataOffset + size),
    });

    const blocks = Math.ceil(size / TAR_BLOCK);
    offset = dataOffset + blocks * TAR_BLOCK;
  }

  return entries;
}

function parseElfRecord(raw: unknown, label: string): BundleManifestElf {
  if (!raw || typeof raw !== "object") {
    throw new Error(`Invalid bundle manifest ${label} descriptor`);
  }
  const obj = raw as Record<string, unknown>;
  if (typeof obj.name !== "string" || typeof obj.identity !== "string" || typeof obj.size !== "number") {
    throw new Error(`Malformed bundle manifest ${label} fields`);
  }
  return { name: obj.name, identity: obj.identity, size: obj.size };
}

function parseBundleManifest(bytes: Uint8Array): BundleManifest {
  if (bytes.length > MAX_MANIFEST_BYTES) {
    throw new Error("Bundle manifest.json exceeds 8192 byte cap");
  }
  const raw = JSON.parse(new TextDecoder().decode(bytes)) as Record<string, unknown>;
  if (raw.format !== "ra8-session-bundle" || raw.version !== 1) {
    throw new Error(`Unsupported bundle manifest format: ${String(raw.format)} v${String(raw.version)}`);
  }
  if (typeof raw.snapshot_version !== "number" || typeof raw.board !== "string" || typeof raw.recording !== "boolean") {
    throw new Error("Malformed bundle manifest metadata");
  }
  const elf0 = parseElfRecord(raw.elf0, "elf0");
  const elf1 = raw.elf1 === null || raw.elf1 === undefined ? null : parseElfRecord(raw.elf1, "elf1");
  return {
    format: raw.format,
    version: raw.version,
    snapshotVersion: raw.snapshot_version,
    board: raw.board,
    elf0,
    elf1,
    recording: raw.recording,
  };
}

/** Preview a staged `.tar` or `.tar.gz` RA8 session bundle manifest and entries. */
export async function previewBundleArchive(bytes: Uint8Array): Promise<BundlePreview> {
  const compressed = isGzipBuffer(bytes);
  const tarBytes = compressed ? await gunzipBuffer(bytes) : bytes;
  const parsed = parseUstarEntries(tarBytes);
  if (parsed.length === 0) {
    throw new Error("Invalid session bundle: archive contains no USTAR entries");
  }
  const manifestEntry = parsed.find((entry) => entry.path === "manifest.json");
  const manifest = manifestEntry ? parseBundleManifest(manifestEntry.data) : null;

  return {
    compressed,
    totalTarBytes: tarBytes.length,
    entries: parsed.map(({ path, size, dataOffset }) => ({ path, size, dataOffset })),
    manifest,
  };
}
