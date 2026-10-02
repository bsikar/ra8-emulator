//! The usage text the emulator prints, kept apart from the flag parser
//! so src/interfaces/cli/cli.zig stays one purpose and under its cap.
pub const text =
    \\usage: ra8_emulator <firmware.elf> [--instructions N] [--part NAME]
    \\                    [--sd-size MB] [--sd-new FS[:LABEL]] [--trace-sd]
    \\                    [--dump-sd BLOCK] [--touch X,Y]
    \\                    [--battery PCT] [--charge] [--click]
    \\                    [--dump-sym NAME] [--stop-sym NAME N] [--ms N]
    \\                    [--break-sym PLACE [N]] [--dump-mem PLACE [N]]
    \\                    [--watch PLACE] [--stop-on-undefined]
    \\                    [--count-pc ADDR] [--trace-rtos] [--cpu-load]
    \\                    [--cpu1 IMAGE.elf] [--cpu unicorn|zig|lockstep]
    \\                    [--ns IMAGE.elf] [--bus-errors]
    \\
    \\  --instructions N   stop after N instructions (default 2000000,
    \\                     or 200000000 when --stop-sym is watching)
    \\  --ms N             stop after N milliseconds of modelled time,
    \\                     counted in the SysTick periods the firmware
    \\                     itself armed
    \\  --part NAME        ra8d2 (default) or ra8p1, which carries the NPU
    \\  --device NAME      the same thing, spelled the way the firmware's
    \\                     own emulator-in-the-loop suite spells it
    \\  --dump-sym NAME    read that global out of RAM after the run and
    \\                     print it, repeatable
    \\  --stop-sym NAME N  end the run early once that global reaches N
    \\  --break-sym PLACE [N]
    \\                     end the run when execution reaches PLACE, on
    \\                     the Nth arrival (default the first); the report
    \\                     says how many arrivals a run that fell short
    \\                     did see. PLACE is a function, an address, or
    \\                     either with a +/- offset, which is how to stop
    \\                     just after a call and read what it returned.
    \\                     --break-at is the same flag, spelled for an
    \\                     address rather than a name
    \\  --cpu1 IMAGE.elf   start the second core on that image, against the
    \\                     same board: shared RAM, shared peripherals. The
    \\                     two cores take turns a chunk at a time. CPU0
    \\                     keeps the clocks and the interrupt controller.
    \\  --ns IMAGE.elf     also load a TrustZone Non-Secure image at its
    \\                     load addresses, where the Secure boot copies it from
    \\  --sd-size MB       size the card on the SPI line (default 32)
    \\  --trace-sd         write one line per SD command to stderr
    \\  --dump-sd BLOCK    print that card block as hex after the run
    \\  --dump-mem PLACE [N]
    \\                     print N words (default 4) out of memory at
    \\                     PLACE, which is an address, a symbol, or
    \\                     @symbol to follow the pointer it holds, any of
    \\                     them with a +/- offset applied afterwards
    \\  --watch PLACE      record every store that lands in that word, with
    \\                     the pc that made it and the function it sits in.
    \\                     Takes the same place spelling as --dump-mem, minus
    \\                     the dereference: the address has to be known
    \\                     before the run starts
    \\  --trace-rtos       record each ThreadX thread switch, the stores to
    \\                     _tx_thread_current_ptr, stamped with modelled time
    \\  --cpu-load         CPU load per ThreadX thread and per ISR, on each
    \\                     core, over the whole run
    \\  --count-pc ADDR    count every execution of the instruction at that
    \\                     address, repeatable up to four times. For
    \\                     settling a disagreement between two counters
    \\                     that are each one step removed from the
    \\                     instruction itself
    \\  --stop-on-undefined
    \\                     end the run the first time it reaches an
    \\                     instruction the architecture leaves undefined,
    \\                     before that instruction executes, so a dump
    \\                     beside it reads the state on the way in
    \\  --dump-regs        print the argument registers and the words at
    \\                     the stack pointer after the run; at a break
    \\                     they are still the arguments of the function
    \\                     stopped on
    \\  --sd-new FS        format that card: fat16 or fat32, with an
    \\                     optional volume label after a colon
    \\  --touch X,Y        queue a contact on the touch panel, repeatable
    \\  --battery PCT      state-of-charge the fuel gauge reports (default 72)
    \\  --charge           report the charger attached, so the charge rate
    \\                     the gauge answers with is positive
    \\  --click            fit the Click module: LSM6DSO 0x6B, MAX17048 0x36
    \\  --bus-errors       raise a precise BusFault for an access nothing
    \\                     maps, as the part does, instead of ending the run
    \\
;
