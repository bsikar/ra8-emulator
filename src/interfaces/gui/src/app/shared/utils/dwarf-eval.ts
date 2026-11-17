import { LocalVariable, LocalWhereKind } from 'ra8-rpc-client';
import { formatHex32 } from './hex';

export interface EvaluatedLocal {
  name: string;
  typeName: string;
  size: number;
  locationLabel: string;
  valueHex: string;
  valueDec: string;
  address: number | null;
}

export interface EvalLocalsOptions {
  frameIndex?: number;
  frameBase?: number | null;
}

interface PendingMemRead {
  index: number;
  address: number;
  readLen: number;
  locLabel: string;
  local: LocalVariable;
}

const DWARF_ARM_REG_NAMES: Record<number, string> = {
  0: 'r0', 1: 'r1', 2: 'r2', 3: 'r3', 4: 'r4', 5: 'r5', 6: 'r6', 7: 'r7',
  8: 'r8', 9: 'r9', 10: 'r10', 11: 'r11', 12: 'r12', 13: 'sp', 14: 'lr', 15: 'pc',
};

function isSignedType(typeName: string): boolean {
  const clean = typeName.trim();
  return /^(int|short|char|long|i8|i16|i32|ssize)/i.test(clean) && !/^u/i.test(clean);
}

function formatScalarBytes(bytes: Uint8Array, size: number, typeName: string): { hex: string; dec: string } {
  const n = Math.min(bytes.length, Math.max(1, size));
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const signed = isSignedType(typeName);
  if (n === 1) {
    const u = view.getUint8(0);
    return { hex: '0x' + u.toString(16).padStart(2, '0'), dec: String(signed ? view.getInt8(0) : u) };
  }
  if (n === 2 && bytes.length >= 2) {
    const u = view.getUint16(0, true);
    return { hex: '0x' + u.toString(16).padStart(4, '0'), dec: String(signed ? view.getInt16(0, true) : u) };
  }
  if (bytes.length >= 4) {
    const u = view.getUint32(0, true) >>> 0;
    return { hex: formatHex32(u), dec: String(signed ? view.getInt32(0, true) : u) };
  }
  const hex = '0x' + Array.from(bytes.subarray(0, n)).map((b) => b.toString(16).padStart(2, '0')).join('');
  return { hex, dec: '' };
}

function evalRegisterLocal(loc: LocalVariable, regs: Record<string, number>, unwound: boolean): EvaluatedLocal {
  const regIdx = Number(loc.whereA);
  const regName = DWARF_ARM_REG_NAMES[regIdx] ?? `r${regIdx}`;
  const regVal = unwound ? undefined : regs[regName];
  if (regVal === undefined) {
    return {
      name: loc.name,
      typeName: loc.typeName || 'reg',
      size: loc.size,
      locationLabel: unwound ? `${regName.toUpperCase()} (unwound)` : regName.toUpperCase(),
      valueHex: '—',
      valueDec: '',
      address: null,
    };
  }
  const u = regVal >>> 0;
  const s = isSignedType(loc.typeName) ? (regVal | 0) : u;
  return {
    name: loc.name,
    typeName: loc.typeName || 'word',
    size: loc.size || 4,
    locationLabel: regName.toUpperCase(),
    valueHex: formatHex32(u),
    valueDec: String(s),
    address: null,
  };
}

function resolveAddress(
  loc: LocalVariable,
  regs: Record<string, number>,
  options: EvalLocalsOptions
): { addr: number | null; locLabel: string } {
  const frameIndex = options.frameIndex ?? 0;
  if (loc.whereKind === LocalWhereKind.Address) {
    const addr = Number(loc.whereA) >>> 0;
    return { addr, locLabel: formatHex32(addr) };
  }
  if (loc.whereKind === LocalWhereKind.Frame) {
    const off = Number(loc.whereA);
    const label = `frame${off >= 0 ? '+' : ''}${off}`;
    const base = options.frameBase !== undefined
      ? options.frameBase
      : frameIndex === 0
        ? (regs['sp'] ?? regs['r7'] ?? null)
        : null;
    return { addr: base !== null ? (base + off) >>> 0 : null, locLabel: label };
  }
  if (loc.whereKind === LocalWhereKind.RegisterIndirect) {
    const regIdx = Number(loc.whereA);
    const regName = DWARF_ARM_REG_NAMES[regIdx] ?? `r${regIdx}`;
    const off = Number(loc.whereB);
    const label = `[${regName.toUpperCase()}${off >= 0 ? '+' : ''}${off}]`;
    const base = frameIndex === 0 ? regs[regName] : undefined;
    return { addr: base !== undefined ? (base + off) >>> 0 : null, locLabel: label };
  }
  return { addr: null, locLabel: 'optimized out' };
}

export async function evaluateLocals(
  locals: readonly LocalVariable[],
  regs: Record<string, number>,
  readMem: (addr: number, len: number) => Promise<Uint8Array | null>,
  options: EvalLocalsOptions = {}
): Promise<EvaluatedLocal[]> {
  const unwound = (options.frameIndex ?? 0) > 0;
  const results: EvaluatedLocal[] = new Array<EvaluatedLocal>(locals.length);
  const pendingReads: PendingMemRead[] = [];

  for (let i = 0; i < locals.length; i++) {
    const loc = locals[i]!;
    if (loc.whereKind === LocalWhereKind.InRegister) {
      results[i] = evalRegisterLocal(loc, regs, unwound);
      continue;
    }
    const { addr, locLabel } = resolveAddress(loc, regs, options);
    const readLen = Math.min(Math.max(loc.size || 4, 1), 8);
    if (addr !== null) {
      pendingReads.push({ index: i, address: addr, readLen, locLabel, local: loc });
    }
    results[i] = {
      name: loc.name,
      typeName: loc.typeName || 'unknown',
      size: loc.size,
      locationLabel: locLabel,
      valueHex: '—',
      valueDec: '',
      address: addr,
    };
  }

  if (pendingReads.length === 0) return results;
  const payloads = await Promise.all(pendingReads.map((req) => readMem(req.address, req.readLen)));
  for (let i = 0; i < pendingReads.length; i++) {
    const req = pendingReads[i]!;
    const mem = payloads[i];
    if (!mem || mem.length === 0) continue;
    const formatted = formatScalarBytes(mem, req.readLen, req.local.typeName);
    results[req.index] = {
      name: req.local.name,
      typeName: req.local.typeName || `${req.readLen}B`,
      size: req.local.size,
      locationLabel: req.locLabel,
      valueHex: formatted.hex,
      valueDec: formatted.dec,
      address: req.address,
    };
  }
  return results;
}
