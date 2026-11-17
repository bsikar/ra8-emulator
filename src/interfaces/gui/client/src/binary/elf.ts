/**
 * Lightweight 32-bit ARM ELF inspector and symbol table extractor.
 */

export interface ElfHeaderInfo {
  valid: boolean;
  entry: number;
  machine: number;
  hasDebugInfo: boolean;
  reason?: string;
}

export interface ElfSymbol {
  name: string;
  address: number;
  size: number;
  kind: "func" | "object" | "other";
}

interface SectionTable {
  shoff: number;
  shentsize: number;
  shnum: number;
  shstrndx: number;
}

function readSectionTable(bytes: Uint8Array, view: DataView): SectionTable | null {
  const shoff = view.getUint32(32, true);
  const shentsize = view.getUint16(46, true);
  const shnum = view.getUint16(48, true);
  const shstrndx = view.getUint16(50, true);
  if (shoff === 0 || shentsize < 40 || shnum === 0) return null;
  if (shoff + shnum * shentsize > bytes.length) return null;
  return { shoff, shentsize, shnum, shstrndx };
}

function readNullTermString(
  bytes: Uint8Array,
  strTabOffset: number,
  strTabSize: number,
  nameIdx: number
): string {
  if (nameIdx >= strTabSize || strTabOffset + strTabSize > bytes.length) return "";
  const start = strTabOffset + nameIdx;
  const maxEnd = strTabOffset + strTabSize;
  let end = start;
  while (end < maxEnd && bytes[end] !== 0) {
    end++;
  }
  if (end <= start) return "";
  return new TextDecoder().decode(bytes.subarray(start, end));
}

function detectDebugSections(bytes: Uint8Array, view: DataView): boolean {
  const table = readSectionTable(bytes, view);
  if (!table || table.shstrndx >= table.shnum) return false;

  const shstrBase = table.shoff + table.shstrndx * table.shentsize;
  const shstrOffset = view.getUint32(shstrBase + 16, true);
  const shstrSize = view.getUint32(shstrBase + 20, true);

  for (let i = 0; i < table.shnum; i++) {
    const base = table.shoff + i * table.shentsize;
    const nameOff = view.getUint32(base, true);
    const secName = readNullTermString(bytes, shstrOffset, shstrSize, nameOff);
    if (secName === ".debug_line" || secName === ".debug_info") {
      return true;
    }
  }
  return false;
}

/** Validate that a buffer is a 32-bit little-endian ARM ELF executable. */
export function inspectElf(bytes: Uint8Array): ElfHeaderInfo {
  if (bytes.length < 52) {
    return { valid: false, entry: 0, machine: 0, hasDebugInfo: false, reason: "File is smaller than an ELF32 header (52 bytes)" };
  }
  if (bytes[0] !== 0x7f || bytes[1] !== 0x45 || bytes[2] !== 0x4c || bytes[3] !== 0x46) {
    return { valid: false, entry: 0, machine: 0, hasDebugInfo: false, reason: "Missing ELF magic header (0x7F 'E' 'L' 'F')" };
  }
  if (bytes[4] !== 1) {
    return { valid: false, entry: 0, machine: 0, hasDebugInfo: false, reason: "Expected 32-bit ARM ELF (found 64-bit ELFCLASS64)" };
  }
  if (bytes[5] !== 1) {
    return { valid: false, entry: 0, machine: 0, hasDebugInfo: false, reason: "Expected little-endian ELFDATA2LSB encoding" };
  }

  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const machine = view.getUint16(18, true);
  const entry = view.getUint32(24, true);
  if (machine !== 40) {
    return {
      valid: false,
      entry,
      machine,
      hasDebugInfo: false,
      reason: `Expected ARM architecture (EM_ARM = 40), got machine ${machine}`,
    };
  }

  return {
    valid: true,
    entry: entry >>> 0,
    machine,
    hasDebugInfo: detectDebugSections(bytes, view),
  };
}

/** Return true if a valid ARM ELF32 image contains DWARF debug sections. */
export function detectElfDwarfSections(bytes: Uint8Array): boolean {
  return inspectElf(bytes).hasDebugInfo;
}

function collectSymtabSection(
  bytes: Uint8Array,
  view: DataView,
  table: SectionTable,
  shBase: number,
  maxSymbols: number,
  seen: Set<string>,
  results: ElfSymbol[]
): void {
  const symOffset = view.getUint32(shBase + 16, true);
  const symSize = view.getUint32(shBase + 20, true);
  const strSectionIdx = view.getUint32(shBase + 24, true);
  const entsize = view.getUint32(shBase + 36, true) || 16;

  if (strSectionIdx >= table.shnum || entsize < 16) return;
  if (symOffset + symSize > bytes.length) return;

  const strShBase = table.shoff + strSectionIdx * table.shentsize;
  const strOffset = view.getUint32(strShBase + 16, true);
  const strSize = view.getUint32(strShBase + 20, true);
  if (strOffset + strSize > bytes.length) return;

  const count = Math.floor(symSize / entsize);
  for (let i = 0; i < count && results.length < maxSymbols; i++) {
    const symBase = symOffset + i * entsize;
    const stName = view.getUint32(symBase, true);
    const stValue = view.getUint32(symBase + 4, true);
    const stSize = view.getUint32(symBase + 8, true);
    const stInfo = bytes[symBase + 12] ?? 0;
    const stShndx = view.getUint16(symBase + 14, true);
    if (stName === 0 || stShndx === 0 || stValue === 0) continue;

    const stType = stInfo & 0x0f;
    if (stType !== 1 && stType !== 2 && stType !== 0) continue;

    const name = readNullTermString(bytes, strOffset, strSize, stName);
    if (!name || name.startsWith("$") || name.startsWith(".L")) continue;

    const kind: ElfSymbol["kind"] =
      stType === 2 ? "func" : stType === 1 ? "object" : "other";
    const address = (kind === "func" ? stValue & ~1 : stValue) >>> 0;
    const dedupKey = `${name}@${address}`;
    if (seen.has(dedupKey)) continue;
    seen.add(dedupKey);
    results.push({ name, address, size: stSize >>> 0, kind });
  }
}

/** Extract function and global object symbols from an ARM ELF32 binary. */
export function parseElfSymbols(bytes: Uint8Array, maxSymbols = 2000): ElfSymbol[] {
  const header = inspectElf(bytes);
  if (!header.valid) return [];

  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const table = readSectionTable(bytes, view);
  if (!table) return [];

  const results: ElfSymbol[] = [];
  const seen = new Set<string>();

  for (let s = 0; s < table.shnum && results.length < maxSymbols; s++) {
    const shBase = table.shoff + s * table.shentsize;
    const shType = view.getUint32(shBase + 4, true);
    if (shType !== 2 && shType !== 11) continue;
    collectSymtabSection(bytes, view, table, shBase, maxSymbols, seen, results);
  }

  results.sort((a, b) => {
    if (a.name === "main" && b.name !== "main") return -1;
    if (b.name === "main" && a.name !== "main") return 1;
    if (a.kind !== b.kind) {
      if (a.kind === "func") return -1;
      if (b.kind === "func") return 1;
    }
    return a.name.localeCompare(b.name);
  });

  return results;
}
