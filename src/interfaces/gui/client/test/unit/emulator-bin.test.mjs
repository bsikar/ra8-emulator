import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { resolveEmulatorBin } from "../helpers/emulator-bin.mjs";

export function run(t) {
  t.section("Emulator Binary Resolution");

  t.test("resolveEmulatorBin honors RA8_EMULATOR_BIN and local zig-out fallback", () => {
    const prev = process.env.RA8_EMULATOR_BIN;
    const tempRoot = mkdtempSync(join(tmpdir(), "ra8-bin-test-"));
    try {
      const binName = process.platform === "win32" ? "ra8_emulator.exe" : "ra8_emulator";
      const localDir = join(tempRoot, "zig-out", "bin");
      const localBin = join(localDir, binName);
      mkdirSync(localDir, { recursive: true });
      writeFileSync(localBin, "");

      delete process.env.RA8_EMULATOR_BIN;
      assert.equal(resolveEmulatorBin(tempRoot), localBin);

      const overrideBin = join(tempRoot, "custom-emu");
      writeFileSync(overrideBin, "");
      process.env.RA8_EMULATOR_BIN = overrideBin;
      assert.equal(resolveEmulatorBin(tempRoot), overrideBin);

      process.env.RA8_EMULATOR_BIN = join(tempRoot, "missing-emu");
      assert.throws(() => resolveEmulatorBin(tempRoot), /missing binary/);
    } finally {
      if (prev === undefined) delete process.env.RA8_EMULATOR_BIN;
      else process.env.RA8_EMULATOR_BIN = prev;
      rmSync(tempRoot, { recursive: true, force: true });
    }
  });

  t.test("resolveEmulatorBin surfaces diagnostics when no binary exists", () => {
    const prev = process.env.RA8_EMULATOR_BIN;
    const empty = mkdtempSync(join(tmpdir(), "ra8-nobin-"));
    try {
      delete process.env.RA8_EMULATOR_BIN;
      assert.throws(() => resolveEmulatorBin(empty), /Could not locate ra8_emulator/);
    } finally {
      if (prev === undefined) delete process.env.RA8_EMULATOR_BIN;
      else process.env.RA8_EMULATOR_BIN = prev;
      rmSync(empty, { recursive: true, force: true });
    }
  });
}
