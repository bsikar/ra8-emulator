//! The usage text the emulator prints, kept apart from the flag parser
//! so src/interfaces/cli/cli.zig stays one purpose and under its cap.
pub const text =
    "usage: ra8_emulator <firmware.elf> [--instructions N] [--part NAME]\n" ++
    "       ra8_emulator --map <firmware.elf>\n" ++
    "       ra8_emulator serve --stdio <firmware.elf>\n" ++
    "       ra8_emulator serve --listen unix:PATH|tcp:[HOST]:PORT <firmware.elf>\n" ++
    "       ra8_emulator ctl --connect unix:PATH|tcp:[HOST]:PORT [--json] " ++
    "load|run|advance|step|pause|regs|mem|snapshot|restore ...\n" ++
    "       ra8_emulator ctl --host NAME [--hosts FILE] --image ELF [--json] " ++
    "load|run|advance|step|pause|regs|mem|snapshot|restore ...\n" ++
    "       ra8_emulator ctl probe HOST PORT capabilities|registers|read ADDRESS " ++
    "LENGTH|halt|step|resume\n" ++
    "       ra8_emulator ctl cpu-load <firmware.elf> [--from N --to N]\n" ++
    "                    [--sd IMAGE | --sd-save IMAGE] [--sd-size MB] [--sd-new " ++
    "FS[:LABEL]] [--trace-sd]\n" ++
    "                    [--dump-sd BLOCK] [--touch X,Y | --touch @PATH | " ++
    "--input-script PATH]\n" ++
    "                    [--battery PCT] [--charge] [--click] [--console]\n" ++
    "                    [--usb-loop] [--usbip PORT] [--cms N] [--sfs N]\n" ++
    "                    [--dump-sym NAME] [--stop-sym NAME N] [--until TEXT] [--ms " ++
    "N]\n" ++
    "                    [--break-sym PLACE [N]] [--dump-mem PLACE [N]]\n" ++
    "                    [--watch PLACE] [--stop-on-undefined]\n" ++
    "                    [--count-pc ADDR] [--trace-rtos] [--cpu-load]\n" ++
    "                    [--profile] [--profile-folded FILE] [--profile-thread TCB]\n" ++
    "                    [--cpu1 IMAGE.elf] [--cpu zig]\n" ++
    "                    [--ns IMAGE.elf] [--no-bus-errors]\n" ++
    "                    [--camera-source KIND[:ARG]] [--history DIR|off] [--kept]\n" ++
    "                    [--checkpoint-every N] [--history-budget BYTES] " ++
    "[--ram-budget BYTES]\n" ++
    "\n" ++
    "  --instructions N   stop after N instructions (default 2000000,\n" ++
    "                     or 200000000 when --stop-sym is watching)\n" ++
    "  --ms N             stop after N milliseconds of modelled time,\n" ++
    "                     counted in the SysTick periods the firmware\n" ++
    "                     itself armed\n" ++
    "  --part NAME        ra8d2 (default), ra8p1 (NPU), ra8e1 (alias fpb-ra8e1),\n" ++
    "                     ra4t1 (alias fpb-ra4t1), hx6538 (or grove-vision-ai-v2),\n" ++
    "                     cortex-m33, cortex-m55, or cortex-m85\n" ++
    "  --sd IMAGE         attach a raw SDHC image (size must be a whole 512 KiB " ++
    "unit)\n" ++
    "  --sd-save IMAGE    the same card, written back over IMAGE when the\n" ++
    "                     run ends (temp file, fsync, rename); --sd\n" ++
    "                     leaves IMAGE untouched\n" ++
    "  --sd-image IMAGE   back the SDHI card with a raw image (whole 512 KiB\n" ++
    "                     units); writes stay in memory unless --sd-writable,\n" ++
    "                     which writes the card back over IMAGE at the end\n" ++
    "  --sd-dir DIR       back the SDHI card with a FAT32 image built from DIR,\n" ++
    "                     the same bytes every build (dotfiles skipped)\n" ++
    "  --app FILE.ra8app  put a ThreadX module app in the SDHI card's root\n" ++
    "                     (beside --sd-dir's files) for the firmware's\n" ++
    "                     loader, after checking its header; repeatable\n" ++
    "                     (FILE.ra8app=MODULE.elf also reads the module's ELF)\n" ++
    "  --device NAME      the same thing, spelled the way the firmware's\n" ++
    "                     own emulator-in-the-loop suite spells it\n" ++
    "  --dump-sym NAME    read that global out of RAM after the run and\n" ++
    "                     print it, repeatable\n" ++
    "  --stop-sym NAME N  end the run early once that global reaches N\n" ++
    "  --until TEXT       end the run early once a console line contains\n" ++
    "                     TEXT, as the bench's uart_scrape does\n" ++
    "  --break-sym PLACE [N]\n" ++
    "                     end the run when execution reaches PLACE, on\n" ++
    "                     the Nth arrival (default the first); the report\n" ++
    "                     says how many arrivals a run that fell short\n" ++
    "                     did see. PLACE is a function, an address, or\n" ++
    "                     either with a +/- offset, which is how to stop\n" ++
    "                     just after a call and read what it returned.\n" ++
    "                     --break-at is the same flag, spelled for an\n" ++
    "                     address rather than a name\n" ++
    "  --cpu1 IMAGE.elf   start the second core on that image, against the\n" ++
    "                     same board: shared RAM, shared peripherals. The\n" ++
    "                     two cores take turns a chunk at a time. CPU0\n" ++
    "                     keeps the clocks and the interrupt controller.\n" ++
    "  --ns IMAGE.elf     also load a TrustZone Non-Secure image at its\n" ++
    "                     load addresses, where the Secure boot copies it from\n" ++
    "  --sd-size MB       size the card on the SPI line (default 32)\n" ++
    "  --trace-sd         write one line per SD command to stderr\n" ++
    "  --dump-sd BLOCK    print that card block as hex after the run\n" ++
    "  --dump-mem PLACE [N] (repeatable, printed in order)\n" ++
    "                     print N words (default 4) out of memory at\n" ++
    "                     PLACE, which is an address, a symbol, or\n" ++
    "                     @symbol to follow the pointer it holds, any of\n" ++
    "                     them with a +/- offset applied afterwards\n" ++
    "  --watch PLACE      record every store that lands in that word, with\n" ++
    "                     the pc that made it and the function it sits in.\n" ++
    "                     Takes the same place spelling as --dump-mem, minus\n" ++
    "                     the dereference: the address has to be known\n" ++
    "                     before the run starts\n" ++
    "  --trace-rtos       record each ThreadX thread switch, the stores to\n" ++
    "                     _tx_thread_current_ptr, stamped with modelled time\n" ++
    "  --trace-rtos-out FILE\n" ++
    "                     --trace-rtos, and write the trace to FILE (CPU1's\n" ++
    "                     to FILE.cpu1) as text a reader can take back\n" ++
    "  --save-state PATH  write the whole run to PATH once the budget is spent\n" ++
    "  --load-state PATH  start from a run --save-state wrote (not with --cpu1)\n" ++
    "  --snapshot-at TIME:PATH\n" ++
    "                     write the run to PATH at the first boundary at or\n" ++
    "                     past virtual TIME (100ns, 40us, 500ms, 2s) and go on\n" ++
    "  --restore PATH     start from a file --snapshot-at wrote (as --load-state)\n" ++
    "  --frame-out PATH   write what the panel shows at the end as a PNG\n" ++
    "  --panel-only       write just the panel, at its own size\n" ++
    "  --frames-out DIR   write numbered P6 panel frames\n" ++
    "  --gif-out PATH     write sampled panel frames as an animated GIF\n" ++
    "  --frames-every N   consider every Nth scanned frame (default 1)\n" ++
    "  --frame-on-settle DIR capture numbered P6 frames as the panel settles\n" ++
    "  --video-out PATH   write a 10 fps grayscale Y4M or ffmpeg MP4\n" ++
    "  --settle-window-ms N require N ms of unchanged GLCDC pixels (default 50)\n" ++
    "  --audio-out PATH   write what SSIE0 transmitted as a WAV (Zig core)\n" ++
    "  --audio-rate HZ    the WAV's sample rate; no audio clock (default 48000)\n" ++
    "  --report json      print the run and cores report as one JSON line\n" ++
    "  --cpu-load         CPU load per ThreadX thread and per ISR, on each\n" ++
    "                     core, over the whole run\n" ++
    "  ctl cpu-load       run an image once and print only its per-core load\n" ++
    "                     object; --from and --to select instruction bounds\n" ++
    "  --profile          count retired instructions and modelled cycles\n" ++
    "                     by ELF function, most cycles first\n" ++
    "  --profile-folded   also write one function count per folded row\n" ++
    "  --profile-thread   fold only the stacks sampled while the ThreadX\n" ++
    "                     thread at this TCB address ran (as --trace-rtos\n" ++
    "                     prints it; 0 for none running). Needs --trace-rtos\n" ++
    "  --count-pc ADDR    count every execution of the instruction at that\n" ++
    "                     address, repeatable up to four times. For\n" ++
    "                     settling a disagreement between two counters\n" ++
    "                     that are each one step removed from the\n" ++
    "                     instruction itself\n" ++
    "  --stop-on-undefined\n" ++
    "                     end the run the first time it reaches an\n" ++
    "                     instruction the architecture leaves undefined,\n" ++
    "                     before that instruction executes, so a dump\n" ++
    "                     beside it reads the state on the way in\n" ++
    "  --dump-regs        print the argument registers and the words at\n" ++
    "                     the stack pointer after the run; at a break\n" ++
    "                     they are still the arguments of the function\n" ++
    "                     stopped on\n" ++
    "  --sd-new FS        format that card: fat16 or fat32, with an\n" ++
    "                     optional volume label after a colon\n" ++
    "  --touch X,Y        queue a contact on the touch panel, repeatable\n" ++
    "  --touch-seq X:Y,X:Y  queue several contacts in order\n" ++
    "  --touch @PATH      read live touches from PATH (a file or FIFO)\n" ++
    "                     while the run goes: one \"X,Y\" per line, with\n" ++
    "                     an optional \"down \"/\"move \" in front; \"up\"\n" ++
    "                     and blank lines add nothing; \"sw1 down\",\n" ++
    "                     \"sw1 up\", \"sw2 down\" and \"sw2 up\" hold and\n" ++
    "                     release the user switches (P009, P008)\n" ++
    "  --battery PCT      state-of-charge the fuel gauge reports (default 72)\n" ++
    "  --charge           report the charger attached, so the charge rate\n" ++
    "                     the gauge answers with is positive\n" ++
    "  --click            fit the Click module: LSM6DSO 0x6B, MAX17048 0x36\n" ++
    "  --board-profile PATH  use a version-1 board profile; optional ospi=\n" ++
    "                     and sdram= lines set size,width,clock_hz,\n" ++
    "                     latency_cycles,burst; memory_window_cycles=N\n" ++
    "                     sets the report bandwidth window\n" ++
    "  --detach c6        remove the default companion MCU\n" ++
    "  --net-record DIR   save every C6 host exchange under DIR\n" ++
    "  --net-replay DIR   answer the C6 from DIR, never the network; a\n" ++
    "                     request with no recording fails the run\n" ++
    "  --attach M@E       attach model M (lsm6dso, max17048, eink, modem, c6,\n" ++
    "                     button, led) at endpoint E: i2c:riic@0x37, spi:spi1@ssl0,\n" ++
    "                     uart:sci3, gpio:P006 (up to 4 times); eink:WxH@E\n" ++
    "                     sizes the panel (default 1072x1448)\n" ++
    "  --fault M@E=MODE   misbehave an --attach part: disconnected, nack:N,\n" ++
    "                     stuck:0xHH, garbage:SEED, slow:NS, stretch:NS,\n" ++
    "                     bus_low\n" ++
    "  --cms N            Secure code MRAM, 32 KB units (CMSAMON.CMS, 0..0x1FF)\n" ++
    "  --sfs N            Secure SiP flash, 32 KB units (SFSAMON.SFS, 0..0x1FF)\n" ++
    "  --console          stream SCI lines and read host input as console RX\n" ++
    "  --console-reply P=LINE  type LINE on the console after a line with P\n" ++
    "  --usb-loop         cable the HS host jack to the board's own FS\n" ++
    "                     device jack, in place of the stand-in device\n" ++
    "  --usbip PORT       export the FS device to usbip hosts on\n" ++
    "                     127.0.0.1:PORT while the run goes (3240 is usbip's)\n" ++
    "  --no-bus-errors    end the run with a fault report on an access\n" ++
    "                     nothing maps, instead of the precise BusFault\n" ++
    "                     the part raises (the default); --bus-errors is\n" ++
    "                     still accepted\n" ++
    "  --rtc-start T      start the RTC running at T (YYYY-MM-DDTHH:MM:SS or\n" ++
    "                     now, UTC) and count virtual time\n" ++
    "  --realtime         pace virtual time against the host clock at 1x\n" ++
    "                     and report achieved speed and drift\n" ++
    "  --speed F          pace at F times real time (0.1, 0.25, 5, 100...),\n" ++
    "                     or max for an unpaced run (the default)\n" ++
    "  --run-for D        run D of the image's own time (30s, 90m, 12h,\n" ++
    "                     7d), counted as --ms counts it\n" ++
    "  --no-idle-skip     a core asleep in WFI/WFE with nothing pending\n" ++
    "                     crosses every boundary instead of running\n" ++
    "                     straight to its next edge (the default;\n" ++
    "                     --idle-skip is still accepted)\n" ++
    "  --camera-source K  where the camera engine's pixels come from (runs on\n" ++
    "                     Session history: RAM by default, or --history DIR):\n" ++
    "                     gradient (the default, no argument),\n" ++
    "                     image:PATH, video:PATH[,loop] (a Y4M clip), or\n" ++
    "                     pipe:PATH|-,WxH,rgb24|yuyv|rgb565 (raw frames),\n" ++
    "                     or webcam[:N|PATH] (Linux, asks before opening),\n" ++
    "                     webcam[:N] (Windows/macOS, asks before opening)\n" ++
    "  --allow-webcam     open the webcam without asking (unattended runs)\n" ++
    "  --history DIR|off  record Session history in DIR, or RAM-only with off\n" ++
    "  --kept             preserve the Session history in DIR after exit\n" ++
    "  --checkpoint-every N write a closed-round checkpoint every N rounds (default " ++
    "64)\n" ++
    "  --history-budget B cap persistent Session history share in bytes (with " ++
    "--history DIR)\n" ++
    "  --ram-budget B     cap RAM-only Session history share in bytes\n" ++
    "  --no-blocks        the Zig core steps one instruction at a time instead\n" ++
    "                     of running formed blocks (the default; --blocks\n" ++
    "                     is still accepted)\n";
