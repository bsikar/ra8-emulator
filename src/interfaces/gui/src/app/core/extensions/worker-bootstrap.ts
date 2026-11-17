/**
 * Isolated Web Worker JavaScript bootstrap generator exposing the `ra8.*` JSON-RPC
 * API inside sandboxed Blob workers.
 */

import type { ExtensionManifest } from './extension-manifest';

function buildWorkerApiPreamble(): string {
  return `'use strict';
const __pending = new Map();
const __handlers = new Map();
let __nextId = 1;
function __callHost(method, params) {
  const id = __nextId++;
  return new Promise((resolve, reject) => {
    __pending.set(id, { resolve, reject });
    self.postMessage({ jsonrpc: '2.0', id, method, params });
  });
}
const ra8 = {
  commands: {
    registerCommand(command, fn) {
      __handlers.set(command, fn);
      return __callHost('ra8.commands.registerCommand', { command });
    },
    executeCommand(command, ...args) {
      return __callHost('ra8.commands.executeCommand', { command, args });
    },
  },
  window: {
    showInformationMessage(message) { return __callHost('ra8.window.showInformationMessage', { message: String(message) }); },
    showWarningMessage(message) { return __callHost('ra8.window.showWarningMessage', { message: String(message) }); },
  },
  debug: {
    getExecutionState() { return __callHost('ra8.debug.getExecutionState', {}); },
    readRegisters(core = 0) { return __callHost('ra8.debug.readRegisters', { core }); },
    readMemory(core = 0, address = 0, length = 64) { return __callHost('ra8.debug.readMemory', { core, address, length }); },
  },
  views: {
    postPanelState(panelId, state) { return __callHost('ra8.views.postPanelState', { panelId, state }); },
  },
};`;
}

function buildWorkerDispatchTail(manifest: ExtensionManifest): string {
  const userSource = JSON.stringify(manifest.mainSource);
  const extId = JSON.stringify(manifest.id);
  return `let __exports = {};
async function __handleHostRequest(msg) {
  try {
    if (msg.method === 'ra8.activate') {
      const module = { exports: {} };
      const factory = new Function('ra8', 'module', 'exports', ${userSource} + '\\nreturn { module, activate: typeof activate === "function" ? activate : undefined, deactivate: typeof deactivate === "function" ? deactivate : undefined };');
      const loaded = factory(ra8, module, module.exports);
      __exports = (loaded && loaded.module && loaded.module.exports) || {};
      const entry = typeof __exports.activate === 'function' ? __exports.activate : loaded.activate;
      if (typeof entry === 'function') await entry({ extensionId: ${extId}, subscriptions: [] });
      self.postMessage({ jsonrpc: '2.0', id: msg.id, result: { registeredCommands: Array.from(__handlers.keys()) } });
      return;
    }
    if (msg.method === 'ra8.command.invoke') {
      const cmd = msg.params && msg.params.command;
      const args = (msg.params && Array.isArray(msg.params.args)) ? msg.params.args : [];
      const fn = __handlers.get(cmd);
      if (typeof fn !== 'function') throw new Error('Command handler not registered: ' + String(cmd));
      const result = await fn(...args);
      self.postMessage({ jsonrpc: '2.0', id: msg.id, result: result === undefined ? null : result });
      return;
    }
    if (msg.method === 'ra8.deactivate') {
      if (typeof __exports.deactivate === 'function') await __exports.deactivate();
      self.postMessage({ jsonrpc: '2.0', id: msg.id, result: { ok: true } });
      return;
    }
    throw new Error('Unknown worker method: ' + String(msg.method));
  } catch (err) {
    self.postMessage({ jsonrpc: '2.0', id: msg.id, error: { code: -32000, message: err && err.message ? err.message : String(err) } });
  }
}
self.onmessage = (event) => {
  const msg = event && event.data;
  if (!msg || msg.jsonrpc !== '2.0') return;
  if (typeof msg.method === 'string' && typeof msg.id === 'number') {
    void __handleHostRequest(msg);
  } else if (typeof msg.id === 'number') {
    const wait = __pending.get(msg.id);
    if (!wait) return;
    __pending.delete(msg.id);
    if (msg.error) wait.reject(new Error(msg.error.message || 'Host RPC error'));
    else wait.resolve(msg.result);
  }
};`;
}

/** Builds the isolated Web Worker bootstrap JavaScript payload for `manifest`. */
export function buildWorkerBootstrapScript(manifest: ExtensionManifest): string {
  return `${buildWorkerApiPreamble()}\n${buildWorkerDispatchTail(manifest)}\n`;
}
