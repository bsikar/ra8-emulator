/**
 * Host project lifecycle RPC codecs (`0x0170..0x0173`)
 * matching `src/interfaces/rpc/project_wire.zig`.
 */

import { decodeTextSlice, encodeText } from "../transport/envelope.js";

export interface ProjectOpenArgs {
  config: string;
}

export interface ProjectBuildArgs {
  recipe: string;
}

export interface ProjectPrepared {
  receipt: string;
}

export function encodeProjectOpen(config: string): Uint8Array {
  return encodeText(config, 4096, "Project config");
}

export function encodeProjectBuild(recipe: string): Uint8Array {
  return encodeText(recipe, 64, "Project recipe");
}

export function decodeProjectPrepared(data: Uint8Array): ProjectPrepared {
  return { receipt: decodeTextSlice(data) };
}
