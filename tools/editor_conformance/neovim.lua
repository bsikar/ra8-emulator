-- Actual nvim-dap client automation. This does not claim manual UI verification.
local config = vim.json.decode(table.concat(vim.fn.readfile(vim.env.RA8_EDITOR_CONFIG), '\n'))
vim.opt.runtimepath:prepend(config.nvimDap)
local dap = require('dap')
local result = { editor = 'Neovim', version = vim.version(), client_revision = config.nvimDapRevision,
  mode = 'headless nvim-dap automation', request = config.request, manual_ui_verified = false,
  assertions = {}, status = 'FAILED' }
local transcript, events = {}, {}

local function snapshot(value, seen, depth)
  if type(value) ~= 'table' then return value end
  seen, depth = seen or {}, depth or 0
  if seen[value] or depth >= 12 then return '<cycle-or-depth-limit>' end
  seen[value] = true
  local copy = {}
  for key, entry in pairs(value) do
    if type(entry) ~= 'function' and type(entry) ~= 'userdata' then
      copy[key] = snapshot(entry, seen, depth + 1)
    end
  end
  seen[value] = nil
  return copy
end

local function wait_for(predicate, label)
  assert(vim.wait(10000, predicate, 20), label .. ' exceeded 10000ms')
end
local function record(direction, value)
  transcript[#transcript + 1] = { direction = direction, message = snapshot(value) }
end
for _, name in ipairs({ 'initialize', 'launch', 'attach', 'configurationDone', 'threads',
  'setBreakpoints', 'setInstructionBreakpoints', 'stackTrace', 'scopes', 'variables',
  'stepIn', 'next', 'stepOut', 'continue', 'pause', 'disconnect' }) do
  dap.listeners.after[name]['ra8-conformance'] = function(_, err, response, request, seq)
    record('response', { command = name, request_seq = seq, request = request,
      success = err == nil, body = response, error = err and tostring(err) or nil })
  end
end
for _, name in ipairs({ 'initialized', 'stopped', 'terminated', 'output' }) do
  dap.listeners.before['event_' .. name]['ra8-conformance'] = function(_, body)
    local event = { event = name, body = body }
    events[#events + 1] = event
    record('event', event)
  end
end
dap.adapters.ra8_conformance = { type = 'server', host = '127.0.0.1', port = config.port,
  options = { initialize_timeout_sec = 10 } }
dap.defaults.ra8_conformance.stepping_granularity = 'instruction'

local function count_stops()
  local count = 0
  for _, event in ipairs(events) do if event.event == 'stopped' then count = count + 1 end end
  return count
end
local function request(command, arguments, expect_error)
  local done, failure, response = false, nil, nil
  assert(dap.session(), 'nvim-dap has an active session'):request(command, arguments, function(err, body)
    failure, response, done = err, body, true
  end)
  wait_for(function() return done end, command)
  if expect_error then assert(failure, command .. ' should reject stale input')
  else assert(not failure, command .. ': ' .. tostring(failure)) end
  return response
end
local function check(name, actual)
  result.assertions[#result.assertions + 1] = { name = name, status = 'PASS', actual = actual }
end

local ok, err = xpcall(function()
  dap.run({ type = 'ra8_conformance', name = 'RA8 conformance', request = config.request,
    program = config.fixture, stopOnEntry = true })
  wait_for(function() return count_stops() > 0 end, 'entry stopped event')
  local stack = request('stackTrace', { threadId = 1 })
  assert(#stack.stackFrames > 0, 'stack frame returned')
  local entry = stack.stackFrames[1]
  assert(entry.instructionPointerReference, 'PC reference')
  if config.expectedEntry then
    assert(tonumber(entry.instructionPointerReference) == config.expectedEntry, 'fixture entry PC')
  end
  check('entry stop and stack', entry)
  local scopes = request('scopes', { frameId = entry.id })
  local registers
  for _, scope in ipairs(scopes.scopes) do if scope.name == 'Registers' then registers = scope end end
  assert(registers, 'register scope is exposed to Neovim')
  local variables = request('variables', { variablesReference = registers.variablesReference })
  assert(#variables.variables >= 16, 'register variables populated')
  check('scopes and register variables', variables)
  local source, line = config.source or entry.source, config.sourceLine or entry.line
  assert(source and source.path and line > 0, 'fixture source location exists')
  vim.cmd.edit(vim.fn.fnameescape(source.path))
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  local before = #transcript
  dap.set_breakpoint()
  wait_for(function()
    for index = before + 1, #transcript do
      local message = transcript[index].message
      if message.command == 'setBreakpoints' and message.success and message.body then
        for _, point in ipairs(message.body.breakpoints or {}) do if point.verified then return true end end
      end
    end
    return false
  end, 'native editor source breakpoint verification')
  dap.toggle_breakpoint()
  request('setBreakpoints', { source = source, breakpoints = {} })
  local points = request('setInstructionBreakpoints', {
    breakpoints = { { instructionReference = entry.instructionPointerReference } } })
  assert(points.breakpoints[1].verified, 'instruction breakpoint verified')
  request('setInstructionBreakpoints', { breakpoints = {} })
  check('native editor source and instruction breakpoints')
  local stopped = count_stops()
  dap.step_into({ granularity = 'instruction' })
  wait_for(function() return count_stops() > stopped end, 'native editor instruction step')
  local stepped = request('stackTrace', { threadId = 1 })
  assert(stepped.stackFrames[1].instructionPointerReference ~= entry.instructionPointerReference,
    'instruction step changes PC')
  check('native editor instruction step', stepped.stackFrames[1])
  request('variables', { variablesReference = registers.variablesReference }, true)
  check('stale variable handle rejected')
  if config.oracle then
    local function wait_stop(action)
      local before = count_stops()
      action()
      wait_for(function() return count_stops() > before end, 'stopped event')
      for index = #events, 1, -1 do
        if events[index].event == 'stopped' then return events[index] end
      end
    end
    dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h') .. '/oracle.lua')
      .verify(request, wait_stop, config.oracle, check)
  end
  local done = false
  dap.disconnect({ terminateDebuggee = false }, function() done = true end)
  wait_for(function() return done end, 'disconnect')
  wait_for(function() return dap.session() == nil end, 'session cleanup')
  check('native editor disconnect')
  result.status = 'PASS'
end, debug.traceback)
if not ok then
  result.error = tostring(err)
  if dap.session() then pcall(dap.disconnect, { terminateDebuggee = false }) end
end
local function sanitize(value)
  if type(value) == 'string' then
    local text = value:gsub('\\', '/')
    for _, replacement in ipairs({ { config.repoRoot, '<repo>' }, { config.output, '<evidence>' } }) do
      local root = replacement[1]:gsub('\\', '/')
      local at = text:lower():find(root:lower(), 1, true)
      if at then text = text:sub(1, at - 1) .. replacement[2] .. text:sub(at + #root) end
    end
    return text
  end
  if type(value) ~= 'table' then return value end
  local copy = {}
  for key, entry in pairs(value) do copy[key] = sanitize(entry) end
  return copy
end
local function save(name, value)
  vim.fn.writefile({ vim.json.encode(sanitize(snapshot(value))) }, config.output .. '/' .. name)
end
save('result.json', result)
save('transcript.json', transcript)
vim.cmd(ok and 'qa!' or 'cquit 1')
