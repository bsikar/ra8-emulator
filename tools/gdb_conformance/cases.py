"""Fixture-defined expected GDB operations and values, no adapter internals."""


def check(expression, name):
    return ['echo ASSERT_EXPECT ' + name + ' ' + expression + "\\n",
            f'printf "ASSERT_RESULT {name} expected=1 actual=%d\\n", !!({expression})',
            "if !(" + expression + ")", 'echo ASSERT_FAIL ' + name + "\\n",
            "quit 1", "end", 'echo ASSERT_PASS ' + name + "\\n"]


def pc(value, name):
    return check(f"$pc == 0x{value:x}", name) + [
        f'printf "ASSERT_PC {name} expected=0x{value:x} actual=0x%x\\n", (unsigned int)$pc']


def execution(oracle):
    s, v = oracle["symbols"], oracle["values"]
    commands = [f"break *0x{s['register_checkpoint']:x}", "continue"]
    commands += pc(s["register_checkpoint"], "register_checkpoint_pc")
    commands += check(f"$r0 == {v['r0']} && $r1 == {v['r1']}", "known_registers")
    commands += check(f"*(unsigned int*)0x{s['known_word']:x} == {v['known_word']}", "known_memory")
    commands += ["set $held_pc = $pc", f"x/wx 0x{s['known_word']:x}", f"x/wx 0x{s['known_word']:x}"]
    commands += check("$pc == $held_pc", "reads_do_not_advance")
    commands += [f"set {{unsigned int}}0x{s['known_word']:x} = 0xaabbccdd"]
    commands += check(f"*(unsigned int*)0x{s['known_word']:x} == 0xaabbccdd", "memory_write_read")
    commands += ["stepi"] + pc(s["register_checkpoint"] + 2, "single_instruction_pc")
    commands += ["delete breakpoints", f"break *0x{s['call_small']:x}", "continue", "nexti"]
    commands += pc(s["after_small"], "small_step_over_return")
    commands += ["delete breakpoints", f"break *0x{s['call_long']:x}", "continue", "nexti"]
    commands += pc(s["after_long"], "long_step_over_return")
    commands += check("$r2 == 0", "long_callee_completed")
    commands += ["detach"]
    return commands, []


def source_stack(oracle):
    s, source = oracle["symbols"], oracle["source"]
    commands = [f"break machine.zig:{source['line']}", "continue"]
    commands += pc(source["address"], "source_break_pc")
    commands += ["bt", "info locals", "delete breakpoints", f"break *0x{s['breakpoint_loop']:x}", "continue"]
    commands += check(f"*(unsigned int*)0x{s['stage']:x} == 42", "nested_result")
    commands += ["detach"]
    return commands, ["machine.nested_inner", "machine.nested_outer", "Reset_Handler", "value=35", "local = 42"]


def step_out(oracle):
    s = oracle["symbols"]
    commands = [f"break *0x{s['small_callee']:x}", "continue", "finish"]
    commands += pc(s["after_small"], "step_out_return")
    commands += ["detach"]
    return commands, []


def dual(oracle):
    s = oracle["cpu1"]["symbols"]
    commands = ["info threads", "thread 2", f"break *0x{s['register_checkpoint']:x}", "continue"]
    commands += pc(s["register_checkpoint"], "cpu1_break_pc")
    commands += check("$r0 == 0x11223344 && $r1 == 0x55667788", "cpu1_registers")
    commands += ["stepi"] + pc(s["register_checkpoint"] + 2, "cpu1_step_pc")
    commands += ["thread 1", "info registers pc", "detach"]
    return commands, ["Thread 2", "Switching to thread 2"]


def fault(oracle):
    s = oracle["fault"]["symbols"]
    commands = [f"break *0x{s['controlled_fault']:x}", "continue", "stepi"]
    commands += pc(s["controlled_fault"], "controlled_fault_pc") + ["detach"]
    return commands, ["Program received signal SIGSEGV"]
