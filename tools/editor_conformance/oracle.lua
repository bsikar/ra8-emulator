-- Independent fixture expectations exercised through nvim-dap's real Session.
local M = {}
function M.verify(request, wait_stop, oracle, check)
  local dap = require('dap')
  local function stack()
    return request('stackTrace', { threadId = 1 }).stackFrames
  end
  local function registers(frame)
    local scopes = request('scopes', { frameId = frame.id }).scopes
    local reference
    for _, scope in ipairs(scopes) do
      if scope.name == 'Registers' then reference = scope.variablesReference end
    end
    local values = request('variables', { variablesReference = assert(reference) }).variables
    local found = {}
    for _, value in ipairs(values) do found[value.name] = tonumber(value.value) end
    return found
  end
  local function at(address)
    local points = request('setInstructionBreakpoints', {
      breakpoints = { { instructionReference = string.format('0x%x', address) } } })
    assert(points.breakpoints[1].verified, 'instruction breakpoint verified')
    local stopped = wait_stop(function() dap.continue() end)
    assert(stopped.body.reason == 'instruction breakpoint', 'fixture instruction breakpoint stop reason')
    local frames = stack()
    assert(tonumber(frames[1].instructionPointerReference) == address, 'fixture breakpoint PC')
    request('setInstructionBreakpoints', { breakpoints = {} })
    return frames
  end
  local frames = at(oracle.ready)
  local values = registers(frames[1])
  for name, expected in pairs(oracle.ready_registers) do
    assert(values[name] == expected, name .. ' at fixture checkpoint')
  end
  check('fixture checkpoint register values', values)
  at(oracle.next.small_call)
  local stopped = wait_stop(function() dap.step_over({ granularity = 'instruction' }) end)
  assert(stopped.body.reason == 'step', 'next stop reason')
  frames = stack()
  assert(tonumber(frames[1].instructionPointerReference) == oracle.next.small_return, 'next return PC')
  check('native call-aware next', frames[1])
  at(oracle.next.long_call)
  stopped = wait_stop(function() dap.step_over({ granularity = 'instruction' }) end)
  assert(stopped.body.reason == 'step', 'long next stop reason')
  frames = stack()
  assert(tonumber(frames[1].instructionPointerReference) == oracle.next.long_return, 'long next return PC')
  assert(registers(frames[1]).r2 == 0, 'long callee finished all iterations')
  check('native multi-slice call-aware next', frames[1])
  local source = { path = oracle.source.path }
  local points = request('setBreakpoints', { source = source,
    breakpoints = { { line = oracle.source.line } } })
  assert(points.breakpoints[1].verified, 'source breakpoint verified')
  stopped = wait_stop(function() dap.continue() end)
  assert(stopped.body.reason == 'breakpoint', 'source stop reason')
  frames = stack()
  assert(#frames >= 2 and frames[1].name:find('nested_inner', 1, true), 'nested fixture stack')
  assert(frames[1].line == oracle.source.line, 'source location is fixture-defined line')
  if oracle.source.address then
    assert(tonumber(frames[1].instructionPointerReference) == oracle.source.address, 'source breakpoint PC')
  end
  check('source breakpoint and nested stack', frames)
  request('setBreakpoints', { source = source, breakpoints = {} })
  stopped = wait_stop(function() dap.step_out({ granularity = 'instruction' }) end)
  assert(stopped.body.reason == 'step', 'step-out reason')
  frames = stack()
  assert(frames[1].name:find('nested_outer', 1, true), 'step-out reaches fixture caller')
  check('native step-out reaches caller', frames[1])
end
return M
