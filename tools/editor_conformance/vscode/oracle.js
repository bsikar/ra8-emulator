'use strict';
const assert = require('assert');

exports.verify = async function verify(request, waitStop, oracle, assertions) {
  async function stack() {
    return (await request('stackTrace', { threadId: 1 })).stackFrames;
  }
  async function registers(frame) {
    const scopes = (await request('scopes', { frameId: frame.id })).scopes;
    const ref = scopes.find(s => s.name === 'Registers').variablesReference;
    const values = (await request('variables', { variablesReference: ref })).variables;
    return Object.fromEntries(values.map(v => [v.name, Number(v.value)]));
  }
  async function at(address) {
    const points = await request('setInstructionBreakpoints', {
      breakpoints: [{ instructionReference: `0x${address.toString(16)}` }]
    });
    assert(points.breakpoints[0].verified);
    const stopped = await waitStop(() => request('continue', { threadId: 1 }));
    assert.equal(stopped.body.reason, 'instruction breakpoint');
    const frames = await stack();
    assert.equal(Number(frames[0].instructionPointerReference), address);
    await request('setInstructionBreakpoints', { breakpoints: [] });
    return frames;
  }
  let frames = await at(oracle.ready);
  const values = await registers(frames[0]);
  for (const [name, expected] of Object.entries(oracle.ready_registers)) {
    assert.equal(values[name], expected, `${name} at fixture checkpoint`);
  }
  assertions.push({ name: 'fixture checkpoint register values', actual: values });
  await at(oracle.next.small_call);
  let stopped = await waitStop(() => request('next', { threadId: 1, granularity: 'instruction' }));
  assert.equal(stopped.body.reason, 'step');
  frames = await stack();
  assert.equal(Number(frames[0].instructionPointerReference), oracle.next.small_return);
  assertions.push({ name: 'call-aware next', actual: frames[0] });
  await at(oracle.next.long_call);
  stopped = await waitStop(() => request('next', { threadId: 1, granularity: 'instruction' }));
  assert.equal(stopped.body.reason, 'step');
  frames = await stack();
  assert.equal(Number(frames[0].instructionPointerReference), oracle.next.long_return);
  assert.equal((await registers(frames[0])).r2, 0);
  assertions.push({ name: 'multi-slice call-aware next', actual: frames[0] });
  const source = { path: oracle.source.path };
  const sourcePoints = await request('setBreakpoints', { source,
    breakpoints: [{ line: oracle.source.line }] });
  assert(sourcePoints.breakpoints[0].verified);
  stopped = await waitStop(() => request('continue', { threadId: 1 }));
  assert.equal(stopped.body.reason, 'breakpoint');
  frames = await stack();
  assert(frames.length >= 2 && frames[0].name.includes('nested_inner'), 'nested fixture call stack');
  assert.equal(frames[0].line, oracle.source.line);
  if (oracle.source.address !== undefined) assert.equal(Number(frames[0].instructionPointerReference), oracle.source.address);
  assertions.push({ name: 'source breakpoint and nested stack', actual: frames });
  await request('setBreakpoints', { source, breakpoints: [] });
  stopped = await waitStop(() => request('stepOut', { threadId: 1, granularity: 'instruction' }));
  assert.equal(stopped.body.reason, 'step');
  frames = await stack();
  assert(frames[0].name.includes('nested_outer'), 'step-out reaches fixture caller');
  assertions.push({ name: 'step-out reaches caller', actual: frames[0] });
};
