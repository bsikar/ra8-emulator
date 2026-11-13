'use strict';
const fs = require('fs');
const path = require('path');
const assert = require('assert');
const vscode = require('vscode');

function deadline(promise, label, ms = 10000) {
  let timer;
  return Promise.race([promise, new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${label} exceeded ${ms}ms`)), ms);
  })]).finally(() => clearTimeout(timer));
}
async function until(test, label) {
  await deadline(new Promise(resolve => {
    const timer = setInterval(() => { if (test()) { clearInterval(timer); resolve(); } }, 20);
    setTimeout(() => clearInterval(timer), 10000);
  }), label);
}
function sanitize(value, config) {
  const replace = item => {
    if (typeof item === 'string') {
      let text = item.replaceAll('\\', '/');
      for (const [root, marker] of [[config.repoRoot, '<repo>'], [config.output, '<evidence>']]) {
        const normalized = root.replaceAll('\\', '/');
        const at = text.toLowerCase().indexOf(normalized.toLowerCase());
        if (at >= 0) text = text.slice(0, at) + marker + text.slice(at + normalized.length);
      }
      return text;
    }
    if (Array.isArray(item)) return item.map(replace);
    if (item && typeof item === 'object') return Object.fromEntries(Object.entries(item).map(([k, v]) => [k, replace(v)]));
    return item;
  };
  return JSON.stringify(replace(value), null, 2);
}
exports.run = async function run() {
  const config = JSON.parse(fs.readFileSync(process.env.RA8_EDITOR_CONFIG, 'utf8'));
  const result = { editor: 'VS Code', version: vscode.version, mode: 'extension-host automation',
    request: config.request, manual_ui_verified: false, assertions: [], status: 'FAILED' };
  let state;
  try {
    const extension = vscode.extensions.getExtension('ra8.ra8-editor-conformance');
    assert(extension, 'development extension is loaded');
    state = await extension.activate();
    const accepted = await deadline(vscode.debug.startDebugging(undefined, {
      type: 'ra8-conformance', name: 'RA8 conformance', request: config.request,
      program: config.fixture, stopOnEntry: true, internalConsoleOptions: 'neverOpen'
    }), 'startDebugging');
    assert(accepted, 'VS Code accepted the debug configuration');
    await until(() => state.events.some(e => e.event === 'stopped'), 'entry stopped event');
    const session = state.session;
    const request = (name, args) => deadline(session.customRequest(name, args), name);
    const waitStop = async action => {
      const before = state.events.filter(e => e.event === 'stopped').length;
      await action();
      await until(() => state.events.filter(e => e.event === 'stopped').length > before, 'stopped event');
      return state.events.filter(e => e.event === 'stopped').at(-1);
    };
    const stack = await request('stackTrace', { threadId: 1 });
    assert(stack.stackFrames.length > 0, 'editor receives a stack frame');
    const entry = stack.stackFrames[0];
    assert(/^0x[0-9a-f]+$/i.test(entry.instructionPointerReference), 'PC reference');
    result.assertions.push({ name: 'entry stop and stack', actual: entry });
    if (config.expectedEntry !== undefined) {
      assert.equal(Number(entry.instructionPointerReference), config.expectedEntry, 'fixture entry PC');
    }
    const scopes = await request('scopes', { frameId: entry.id });
    const registers = scopes.scopes.find(s => s.name === 'Registers');
    assert(registers, 'register scope is exposed to VS Code');
    const variables = await request('variables', { variablesReference: registers.variablesReference });
    assert(variables.variables.some(v => v.name === 'pc'), 'register variables populated');
    result.assertions.push({ name: 'scopes and register variables', actual: variables });
    const source = config.source || entry.source;
    const line = config.sourceLine || entry.line;
    assert(source && source.path && line > 0, 'fixture source location exists');
    const breakpoint = new vscode.SourceBreakpoint(new vscode.Location(
      vscode.Uri.file(source.path), new vscode.Position(line - 1, 0)));
    vscode.debug.addBreakpoints([breakpoint]);
    await until(() => state.messages.some(x => x.direction === 'adapter'
      && x.message.type === 'response' && x.message.command === 'setBreakpoints'
      && x.message.success && x.message.body.breakpoints.some(b => b.verified)), 'source breakpoint verification');
    vscode.debug.removeBreakpoints([breakpoint]);
    await request('setBreakpoints', { source, breakpoints: [] });
    const instruction = await request('setInstructionBreakpoints', {
      breakpoints: [{ instructionReference: entry.instructionPointerReference }]
    });
    assert(instruction.breakpoints[0].verified, 'instruction breakpoint verified');
    await request('setInstructionBreakpoints', { breakpoints: [] });
    result.assertions.push({ name: 'editor source and instruction breakpoints', status: 'PASS' });
    const stopped = state.events.filter(e => e.event === 'stopped').length;
    await request('stepIn', { threadId: 1, granularity: 'instruction' });
    await until(() => state.events.filter(e => e.event === 'stopped').length > stopped, 'instruction step');
    assert.equal(state.events.filter(e => e.event === 'stopped').at(-1).body.reason, 'step');
    const stepped = await request('stackTrace', { threadId: 1 });
    assert.notEqual(stepped.stackFrames[0].instructionPointerReference, entry.instructionPointerReference);
    result.assertions.push({ name: 'instruction step changes PC', actual: stepped.stackFrames[0] });
    let staleRejected = false;
    try { await request('variables', { variablesReference: registers.variablesReference }); }
    catch (_) { staleRejected = true; }
    assert(staleRejected, 'stale variable handle rejected');
    result.assertions.push({ name: 'stale variable handle', status: 'PASS' });
    if (config.oracle) await require('./oracle').verify(request, waitStop, config.oracle, result.assertions);
    const initialize = state.messages.find(x => x.direction === 'client' && x.message.command === 'initialize');
    const configured = state.messages.find(x => x.direction === 'client' && x.message.command === 'configurationDone');
    assert(initialize && configured, 'native editor client negotiated and configured DAP');
    await deadline(vscode.debug.stopDebugging(session), 'stopDebugging');
    await until(() => state.events.some(e => e.event === 'terminated'), 'terminated');
    result.status = 'PASS';
  } catch (error) {
    result.error = String(error.stack || error);
    if (state && state.session) await vscode.debug.stopDebugging(state.session);
  } finally {
    fs.writeFileSync(path.join(config.output, 'result.json'), sanitize(result, config));
    fs.writeFileSync(path.join(config.output, 'transcript.json'), sanitize(state ? state.messages : [], config));
  }
  assert.equal(result.status, 'PASS', result.error);
};
