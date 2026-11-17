/**
 * RA8 Emulator RPC Client Package
 *
 * Barrel exports for wire types, codecs, WebSocket RPC client, framebuffer,
 * ELF32 inspector, USTAR bundle header reader, and `.board` profile parser/serializer.
 */

export * from "./wire/types.js";
export * from "./wire/session.js";
export * from "./wire/debug.js";
export * from "./wire/history.js";
export * from "./wire/metrics.js";
export * from "./wire/workspace.js";
export * from "./wire/build.js";
export * from "./wire/project.js";
export * from "./wire/artifacts.js";
export * from "./wire/targets.js";

export * from "./transport/envelope.js";
export * from "./transport/emitter.js";
export * from "./transport/dispatch.js";
export * from "./transport/ws-transport.js";
export * from "./transport/ws-session.js";
export * from "./transport/ws-debug.js";
export * from "./transport/ws-client.js";

export * from "./binary/crc32.js";
export * from "./binary/elf.js";
export * from "./binary/framebuffer.js";
export * from "./binary/ustar.js";
export * from "./binary/board-profile.js";
