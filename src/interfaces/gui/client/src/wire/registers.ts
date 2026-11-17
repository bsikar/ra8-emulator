/**
 * ARM Cortex-M85 / Cortex-M33 register IDs and batched read groups
 * matching `src/interfaces/rpc/session/register.zig`.
 */

import { Core } from "./types.js";

/** ARM Cortex-M registers (`Register` in `register.zig`). */
export enum Register {
  Pc = 0,
  Sp = 1,
  Lr = 2,
  R0 = 3,
  R1 = 4,
  R2 = 5,
  R3 = 6,
  R12 = 7,
  Xpsr = 8,
  Primask = 9,
  Psp = 10,
  R4 = 11,
  R5 = 12,
  R6 = 13,
  R7 = 14,
  R8 = 15,
  R9 = 16,
  R10 = 17,
  R11 = 18,
  Msp = 19,
  Basepri = 20,
  Faultmask = 21,
  Control = 22,
  Fpscr = 23,
  Msplim = 24,
  Psplim = 25,
  S0 = 26,
  S1 = 27,
  S2 = 28,
  S3 = 29,
  S4 = 30,
  S5 = 31,
  S6 = 32,
  S7 = 33,
  S8 = 34,
  S9 = 35,
  S10 = 36,
  S11 = 37,
  S12 = 38,
  S13 = 39,
  S14 = 40,
  S15 = 41,
  S16 = 42,
  S17 = 43,
  S18 = 44,
  S19 = 45,
  S20 = 46,
  S21 = 47,
  S22 = 48,
  S23 = 49,
  S24 = 50,
  S25 = 51,
  S26 = 52,
  S27 = 53,
  S28 = 54,
  S29 = 55,
  S30 = 56,
  S31 = 57,
  Vpr = 58,
}

export interface RegisterEntry {
  readonly name: string;
  readonly reg: Register;
}

export const COMMON_REGISTERS: readonly RegisterEntry[] = [
  { name: "pc", reg: Register.Pc },
  { name: "sp", reg: Register.Sp },
  { name: "lr", reg: Register.Lr },
  { name: "r0", reg: Register.R0 },
  { name: "r1", reg: Register.R1 },
  { name: "r2", reg: Register.R2 },
  { name: "r3", reg: Register.R3 },
  { name: "r4", reg: Register.R4 },
  { name: "r5", reg: Register.R5 },
  { name: "r6", reg: Register.R6 },
  { name: "r7", reg: Register.R7 },
  { name: "r8", reg: Register.R8 },
  { name: "r9", reg: Register.R9 },
  { name: "r10", reg: Register.R10 },
  { name: "r11", reg: Register.R11 },
  { name: "r12", reg: Register.R12 },
  { name: "xpsr", reg: Register.Xpsr },
  { name: "msp", reg: Register.Msp },
  { name: "psp", reg: Register.Psp },
];

export const SYS_REGISTERS: readonly RegisterEntry[] = [
  { name: "primask", reg: Register.Primask },
  { name: "basepri", reg: Register.Basepri },
  { name: "faultmask", reg: Register.Faultmask },
  { name: "control", reg: Register.Control },
  { name: "msplim", reg: Register.Msplim },
  { name: "psplim", reg: Register.Psplim },
];

export const FPU_MVE_REGISTERS: readonly RegisterEntry[] = [
  { name: "fpscr", reg: Register.Fpscr },
  { name: "vpr", reg: Register.Vpr },
  ...Array.from({ length: 32 }, (_, idx): RegisterEntry => ({
    name: `s${idx}`,
    reg: (Register.S0 + idx) as Register,
  })),
];

export const EXTENDED_REGISTERS: readonly RegisterEntry[] = [
  ...COMMON_REGISTERS,
  ...SYS_REGISTERS,
  ...FPU_MVE_REGISTERS,
];

/** Batch-read a list of registers concurrently using `Promise.all`. */
export async function readRegisterBatch(
  readOne: (core: Core, register: Register) => Promise<number>,
  core: Core,
  entries: readonly RegisterEntry[]
): Promise<Record<string, number>> {
  const values = await Promise.all(
    entries.map(async (entry) => ({ name: entry.name, value: await readOne(core, entry.reg) }))
  );
  const out: Record<string, number> = {};
  for (const item of values) {
    out[item.name] = item.value;
  }
  return out;
}
