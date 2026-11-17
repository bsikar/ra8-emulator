import { execFileSync, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HELPER_DIR = dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = resolve(HELPER_DIR, "../../../../../..");

function emulatorBinaryName() {
  return process.platform === "win32" ? "ra8_emulator.exe" : "ra8_emulator";
}

export function resolveEmulatorBin(repoRoot = REPO_ROOT) {
  const binName = emulatorBinaryName();
  const envBin = process.env.RA8_EMULATOR_BIN?.trim();
  if (envBin) {
    const resolvedEnv = resolve(envBin);
    if (existsSync(resolvedEnv)) return resolvedEnv;
    throw new Error(`RA8_EMULATOR_BIN points to missing binary: ${resolvedEnv}`);
  }

  const localBin = resolve(repoRoot, "zig-out", "bin", binName);
  if (existsSync(localBin)) return localBin;

  let gitDetail = "";
  try {
    const commonDir = execFileSync("git", ["rev-parse", "--git-common-dir"], {
      cwd: repoRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
    if (commonDir) {
      const commonBin = resolve(repoRoot, commonDir, "..", "zig-out", "bin", binName);
      if (existsSync(commonBin)) return commonBin;
      gitDetail = ` or ${commonBin}`;
    }
  } catch (err) {
    gitDetail = ` (git rev-parse failed: ${err instanceof Error ? err.message : String(err)})`;
  }

  throw new Error(`Could not locate ${binName} in RA8_EMULATOR_BIN, ${localBin}${gitDetail}`);
}

export function resolveFixtureElf(relPath = "tests/fixtures/gpio/blink.elf", repoRoot = REPO_ROOT) {
  return resolve(repoRoot, relPath);
}

export async function startEmulatorServe(port, fixtureElf, options = {}) {
  const emulatorPath = resolveEmulatorBin(options.repoRoot ?? REPO_ROOT);
  const proc = spawn(emulatorPath, ["serve", "--listen", `tcp:127.0.0.1:${port}`, fixtureElf], {
    stdio: ["pipe", "pipe", "pipe"],
  });

  await waitForServeListening(proc, options.timeoutMs ?? 5000, options);
  return {
    proc,
    emulatorPath,
    stop() {
      if (!proc.killed) proc.kill("SIGTERM");
    },
  };
}

function waitForServeListening(proc, timeoutMs, options) {
  return new Promise((resolveReady, rejectReady) => {
    let settled = false;
    let stderrTail = "";
    const finish = (err) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (err) {
        if (!proc.killed) proc.kill("SIGTERM");
        rejectReady(err);
      } else {
        resolveReady(undefined);
      }
    };

    const timer = setTimeout(() => {
      finish(new Error(`Emulator server did not start within ${timeoutMs}ms: ${stderrTail.trim()}`));
    }, timeoutMs);

    proc.on("error", (err) => finish(new Error(`Emulator failed to start: ${err.message}`)));
    proc.on("exit", (code, signal) => {
      finish(new Error(`Emulator exited before listening (code=${code}, signal=${signal}): ${stderrTail.trim()}`));
    });
    proc.stdout?.on("data", (data) => options.onStdout?.(data.toString().trim()));
    proc.stderr?.on("data", (data) => {
      const text = data.toString();
      stderrTail = (stderrTail + text).slice(-500);
      options.onStderr?.(text.trim());
      if (text.includes("serve: listening on tcp:")) finish(null);
    });
  });
}
