//! The usage text the emulator prints, kept apart from the flag parser
//! so src/interfaces/cli/cli.zig stays one purpose and under its cap.
pub const text =
    \\usage: ra8_emulator <firmware.elf> [--instructions N] [--part NAME]
    \\       ra8_emulator ctl cpu-load <firmware.elf> [--from N --to N]
    \\                    [--sd IMAGE | --sd-save IMAGE] [--sd-size MB] [--sd-new FS[:LABEL]] [--trace-sd]
    \\                    [--dump-sd BLOCK] [--touch X,Y | --touch @PATH]
    \\                    [--battery PCT] [--charge] [--click] [--console]
    \\                    [--usb-loop] [--usbip PORT] [--cms N] [--sfs N]
    \\                    [--dump-sym NAME] [--stop-sym NAME N] [--until TEXT] [--ms N]
    \\                    [--break-sym PLACE [N]] [--dump-mem PLACE [N]]
    \\                    [--watch PLACE] [--stop-on-undefined]
    \\                    [--count-pc ADDR] [--trace-rtos] [--cpu-load]
    \\                    [--profile] [--profile-folded FILE]
    \\                    [--cpu1 IMAGE.elf] [--cpu zig|unicorn]
    \\                    [--ns IMAGE.elf] [--no-bus-errors]
    \\                    [--camera-source KIND[:ARG]]
    \\
    \\  --instructions N   stop after N instructions (default 2000000,
    \\                     or 200000000 when --stop-sym is watching)
    \\  --ms N             stop after N milliseconds of modelled time,
    \\                     counted in the SysTick periods the firmware
    \\                     itself armed
    \\  --part NAME        ra8d2 (default) or ra8p1, which carries the NPU
    \\  --sd IMAGE         attach a raw SDHC image (size must be a whole 512 KiB unit)
    \\  --sd-save IMAGE    the same card, written back over IMAGE when the
    \\                     run ends (temp file, fsync, rename); --sd
    \\                     leaves IMAGE untouched
    \\  --device NAME      the same thing, spelled the way the firmware's
    \\                     own emulator-in-the-loop suite spells it
    \\  --dump-sym NAME    read that global out of RAM after the run and
    \\                     print it, repeatable
    \\  --stop-sym NAME N  end the run early once that global reaches N
    \\  --until TEXT       end the run early once a console line contains
    \\                     TEXT, as the bench's uart_scrape does
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
    \\  --dump-mem PLACE [N] (repeatable, printed in order)
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
    \\  --trace-rtos-out FILE
    \\                     --trace-rtos, and write the trace to FILE (CPU1's
    \\                     to FILE.cpu1) as text a reader can take back
    \\  --frame-out PATH   write what the panel shows at the end as a PNG
    \\  --panel-only       write just the panel, at its own size
    \\  --frames-out DIR   write numbered P6 panel frames
    \\  --gif-out PATH     write sampled panel frames as an animated GIF
    \\  --frames-every N   consider every Nth scanned frame (default 1)
    \\  --report json      print the run and cores report as one JSON line
    \\  --cpu-load         CPU load per ThreadX thread and per ISR, on each
    \\                     core, over the whole run
    \\  ctl cpu-load       run an image once and print only its per-core load
    \\                     object; --from and --to select instruction bounds
    \\  --profile          count retired instructions and modelled cycles
    \\                     by ELF function, most cycles first
    \\  --profile-folded   also write one function count per folded row
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
    \\  --touch-seq X:Y,X:Y  queue several contacts in order
    \\  --touch @PATH      read live touches from PATH (a file or FIFO)
    \\                     while the run goes: one "X,Y" per line, with
    \\                     an optional "down "/"move " in front; "up"
    \\                     and blank lines add nothing; "sw1 down",
    \\                     "sw1 up", "sw2 down" and "sw2 up" hold and
    \\                     release the user switches (P009, P008)
    \\  --battery PCT      state-of-charge the fuel gauge reports (default 72)
    \\  --charge           report the charger attached, so the charge rate
    \\                     the gauge answers with is positive
    \\  --click            fit the Click module: LSM6DSO 0x6B, MAX17048 0x36
    \\  --attach M@E       attach model M (lsm6dso, max17048, eink, modem, button,
    \\                     led) at endpoint E: i2c:riic@0x37, spi:spi1@ssl0,
    \\                     uart:sci3, gpio:P006 (up to 4 times); eink:WxH@E
    \\                     sizes the panel (default 1072x1448)
    \\  --fault M@E=MODE   misbehave an --attach part: disconnected, nack:N,
    \\                     stuck:0xHH, garbage:SEED, slow:NS, stretch:NS,
    \\                     bus_low
    \\  --cms N            Secure code MRAM, 32 KB units (CMSAMON.CMS, 0..0x1FF)
    \\  --sfs N            Secure SiP flash, 32 KB units (SFSAMON.SFS, 0..0x1FF)
    \\  --console          stream SCI lines and read host input as console RX
    \\  --usb-loop         cable the HS host jack to the board's own FS
    \\                     device jack, in place of the stand-in device
    \\  --usbip PORT       export the FS device to usbip hosts on
    \\                     127.0.0.1:PORT while the run goes (3240 is usbip's)
    \\  --no-bus-errors    end the run with a fault report on an access
    \\                     nothing maps, instead of the precise BusFault
    \\                     the part raises (the default); --bus-errors is
    \\                     still accepted
    \\  --rtc-start T      start the RTC running at T (YYYY-MM-DDTHH:MM:SS or
    \\                     now, UTC) and count virtual time
    \\  --camera-source K  where the camera engine's pixels come from:
    \\                     gradient (the default, no argument),
    \\                     image:PATH, video:PATH[,loop] (a Y4M clip), or
    \\                     pipe:PATH|-,WxH,rgb24|yuyv|rgb565 (raw frames)
    \\  --no-blocks        the Zig core steps one instruction at a time instead
    \\                     of running formed blocks (the default; --blocks
    \\                     is still accepted)
    \\
;
