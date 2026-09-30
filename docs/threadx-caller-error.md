# Why threadx_blink never blinks

Two symptoms, one mechanism. This file records what is established first-hand and
what is still open, so the fix does not start over.

## The symptoms

`threadx_blink` is two threads at the same priority, both looping
`toggle LED; g_threadx_blink_tick++; tx_thread_sleep(n)`, thread A with n=500 and
thread B with n=1000, on a 1000 Hz tick. Over 4 s it should give about 8 and 4
toggles. What the model does instead:

- every one of the first 151 tick increments lands inside the first 25 ms, then
  thread A goes silent. The count reads 151 at `--ms 25` and still 151 at
  `--ms 300`.
- a second burst takes it to 301 somewhere between 500 ms and 900 ms, and there
  it stops for good: 301 at `--ms 1000` and at `--ms 4000`.
- LED2 then runs away on its own: 151 at `--ms 1000`, 596538 at 1100 ms,
  18066461 at 4000 ms.

## The mechanism

`_tx_thread_sleep` has four guards that return `TX_CALLER_ERROR` **without
sleeping** (`libs/third_party/threadx/common_smp/src/tx_thread_sleep.c`):
a null `_tx_thread_current_ptr` (line 84), a non-zero system state (95), the
timer thread itself (108), and a non-zero `_tx_thread_preempt_disable` (133).

The app writes `(void)tx_thread_sleep(...)` and discards the status. So a sleep
that refuses to block is not an error the app notices; it is a thread that
falls straight through its loop and spins. That is what both bursts are.

Which guard fires is now known, sampled over a run:

| at | system_state | current_ptr | preempt_disable | tick |
|----|----|----|----|----|
| 10 ms | 0 | 0 | 0 | 151 |
| 100 ms | 0 | 0 | 0 | 151 |
| 500 ms | 0 | 0 | 0 | 151 |
| 1000 ms | 0 | 0 | **1** | 301 |
| 2000 ms | 0 | 0x220008F8 | **1** | 301 |

`_tx_thread_system_state` is 0 throughout, so guard 95 never fires and the
interrupt bookkeeping is not at fault. The other two both do:

- **the boot burst** is guard 84. A thread body is running while
  `_tx_thread_current_ptr` still reads 0, so every sleep it takes is refused.
- **the freeze** is guard 133. `_tx_thread_preempt_disable` reaches 1 at
  1000 ms and never returns to 0. From then on every sleep in the image is
  refused, which is exactly the LED2 runaway.

## What is ruled out

- **The tick.** `_tx_timer_system_clock` is exact at every sample: 199 at
  200 ms, 499 at 500, 899 at 900, 999 at 1000, 1999 at 2000. SysTick is
  delivered once per millisecond (1004 taken over 1000 ms).
- **Timer expiry.** `_tx_timer_expired` is set from `SysTick_Handler+0x20` and
  cleared from `_tx_timer_expiration_process+0x72`, 97 stores over 1200 ms.
  ThreadX walks a long sleep down by `TX_TIMER_ENTRIES` a pass and re-arms 31
  slots ahead, so roughly 15 passes per 500-tick sleep; 48 expiry cycles over
  1200 ms is that shape, not a runaway.
- **Memory overlap.** `g_threadx_blink_tick` at 0x220009A8 sits immediately
  after `s_thread_b` (0x220008F8 + 0xB0), adjacent and not overlapping, so the
  counter is not being clobbered by thread bookkeeping. The 151 and 301 are
  real toggles, and the GPIO side agrees with them.

## Where the fault actually sits

Measured after the watch learned to keep both ends of a place (#268), which is
what made any of this readable.

`_tx_thread_preempt_disable` takes 920 stores over 1200 ms. Counted by site,
that is 452 increments from `_tx_thread_sleep+0xAE` against 451 decrements from
`_tx_thread_system_suspend+0x54`. One unpaired increment is the whole freeze.

The window that increment opens is **deliberately interruptible**, so an
interrupt landing in it is not the bug. `_tx_thread_sleep` stores the increment
at 0x020022A6 and then restores PRIMASK at 0x020022AE, four instructions later,
before it calls `_tx_thread_system_suspend` at 0x020022B6. ThreadX guards the
window with the flag itself, not with a mask, which is what
`#ifndef TX_NOT_INTERRUPTABLE` around the decrement means. So the thread is
expected to be interrupted there and expected to come back and finish.

It never comes back. That is ours, and this is the evidence:

- `_tx_thread_execute_ptr` takes 305 stores, and **the last one sets it to
  0x220008F8**, written by `_tx_thread_system_resume+0xC0` by way of
  `_tx_thread_timeout+0x40`. So ThreadX has picked a thread to run and said so.
- The run nonetheless parks with 94% of its boundary samples at pc
  0x0200029C, inside `__tx_ts_wait`. That loop reads `_tx_thread_execute_ptr`,
  stores it to `_tx_thread_current_ptr`, and leaves on `cbnz` the moment the
  value is non-zero.

A scheduler that has named its next thread, and a machine sitting in the loop
whose only job is to notice that, do not belong in the same run. The question
is no longer why ThreadX latches; it is why the wait loop does not observe a
word that has already been written.

## Ruled out, each of which looked right

- **Delivering an interrupt through ThreadX's mask.** Over 1200 ms the run
  reports 1023 pends waited out a mask over 4518 instructions, with **0
  abandoned and 0 still masked**, and 1204 taken against 1203 returned. The
  unmask seam's step bound is never reached in this image.
- **BASEPRI masking we do not model.** This port can mask with BASEPRI instead
  of PRIMASK, and we honour only PRIMASK, so it looked like the answer. The
  built image contains **zero `msr BASEPRI` instructions**, so this ThreadX is
  masking with `cpsid`, which we do honour.
- **A thread starved by its sibling.** Both threads are refused equally; thread
  B is not special. The earlier reading, that B stops blocking after its first
  expiry and starves A, is wrong.

### The idle seam, measured this time rather than reasoned about

`__tx_ts_wait` is a spin, the idle seam skips spins, and the seam's own
proof is a register comparison, so the seam looked like the obvious way the
model could go blind to a word an interrupt had just written. It is not
what is happening here.

The seam holds a proved-idle state in `known` and `resting` re-checks it
with registers alone, which is genuinely too weak: a handler can store the
word a spin waits on and then return leaving that spin's registers exactly
as it found them. That hole is now closed (`Seam.stir`, called from
`run_loop.service` whenever a handler is actually entered), and closing it
changed nothing:

- all 36 corpus images produce byte-identical reports before and after,
- `threadx_blink` still reports the same tick, 301, at 1 s, 2 s and 4 s.

The reason is that the hole is nearly unreachable in practice. A handler
does not run between two instructions of the spin; it runs across chunk
boundaries, so at the next boundary the program counter is usually inside
the handler rather than at the head of the loop, `resting` fails on its
own, and the seam re-probes anyway. The counters say so directly: over a
1200 ms run the seam records 1000 closures across 18995 boundaries, so it
is already re-proving the loop roughly once per interrupt rather than
riding one stale proof.

So the skipping is honest. When the seam skips `__tx_ts_wait` the loop
really would not have exited, and the instructions are still charged to the
clocks, so the interrupt still arrives at the modelled time it should. The
freeze is not the model failing to notice a store; it is thread B spinning
because its sleep was refused, which is what the rest of this document is
about.

## What to read first

Whether the idle seam is what keeps the wait loop from seeing the store. The
seam skips a spin it has proven cannot change anything and charges the modelled
time instead, and `__tx_ts_wait` is a spin whose exit condition is a word an
interrupt writes. If the seam's proof treats that load as inert, the loop would
keep being skipped after the value it waits on has already changed, which is
exactly the shape above. Start at `src/core/idle.zig` and the boundary sampling
in `src/core/run_loop.zig`, and check what the seam concludes about a loop that
loads from memory rather than only from registers.

The boot burst (guard 84, a thread body running with a null `current_ptr`) may
be the same fault one step earlier, since a null `current_ptr` is what the wait
loop writes when `execute_ptr` reads 0. Do not assume one fix covers both until
that is shown.

## The unpaired increment, located by tally

Measured on `threadx_blink` at 2000 ms, watching
`_tx_thread_preempt_disable`. The word takes 920 stores. Tallied by the
pair (pc, value) rather than read off the two ends of the list:

    452 store(s) of 0x00000001 from _tx_thread_sleep+0xAE
    451 store(s) of 0x00000000 from _tx_thread_system_suspend+0x54
      4 store(s) of 0x00000001 from _tx_thread_system_resume+0x3A
      2 store(s) of 0x00000002 from _txe_thread_create+0x42
      2 store(s) of 0x00000001 from _txe_thread_create+0xF0
      2 store(s) of 0x00000002 from _tx_thread_create+0x130
      2 store(s) of 0x00000002 from _tx_thread_timeout+0x2C
      1 store(s) of 0x00000000 from Reset_Handler+0x6E

Exactly one sleep incremented the flag and its suspend never wrote the
decrement back. That is the whole of the floor of 1, and it is one store
missing out of 920, which is why no length of list found it.

Two things this rules out, both of which had looked plausible.

Boot is clean. `_tx_initialize_kernel_enter+0x26` sets the flag to 1
once, and a store of 0 from pc 0x02000206 (the port's
`_tx_thread_schedule`, which carries no sized symbol, the same as
`__tx_ts_wait`) clears it before the threads run. The assembly means to
do exactly that: `tx_thread_schedule.S:86` builds the address and the
next instruction stores zero, commented "Clear the preempt-disable flag
to enable rescheduling after initialization". So the flag really is 0
when thread A takes its first sleep, and 452 sleeps got through.

The wait loop is not stuck. At the end of the same run
`_tx_thread_execute_ptr` and `_tx_thread_current_ptr` both read
0x220008F8, thread B. `__tx_ts_wait` loaded the execute pointer and
stored it into the current pointer, which is its whole job, so it left.
The 47% of boundary samples at 0x0200029C is where boundaries land, not
a machine parked there. The earlier note pointing at that loop is
superseded by this measurement.

What is left is a deadlock with a named mechanism. Thread A is stranded
inside `_tx_thread_system_suspend`, past the increment in
`_tx_thread_sleep` and short of the decrement at suspend+0x54. Nothing
can resume A without a context switch, and `tx_timer_interrupt.S:222`
reads the flag and skips issuing PendSV whenever it is non-zero:

    BL      _tx_thread_time_slice
    LDR     r0, =_tx_thread_preempt_disable
    LDR     r1, [r0]
    CBNZ    r1, __tx_timer_skip_time_slice

So the one stranded suspend holds the flag at 1, the flag stops every
later PendSV, and the run keeps thread B spinning on a sleep that
`tx_thread_sleep.c:133` refuses because the flag is non-zero. Both
observed effects follow from one missing store.

The open question is narrow now: what took control away from thread A
between `_tx_thread_sleep+0xAE` and `_tx_thread_system_suspend+0x54`,
and why it never came back. That window is interruptible by design
(sleep restores PRIMASK at 0x020022AE before calling suspend at
0x020022B6), so an exception there is ordinary and hardware finishes the
call afterwards. This model takes exceptions only at chunk boundaries,
so the next measurement to make is whether a boundary switch lands in
that window more readily than hardware would, and whether the frame it
stacks for A is one A can ever return on.

## The stranding exception, caught by a window

The tally in the section above located the unpaired increment but could
not show the exception that caused it, and never could: a tally displaces
its rarest row when the table fills, and a once-per-run event is exactly
that row. `src/debug/taken_in.zig` answers it instead. Name a function,
keep every exception taken inside it, evict nothing:

    ra8_emulator threadx_blink.elf --ms 2000 --taken-in _tx_thread_sleep

Over 2000 modelled milliseconds, `_tx_thread_sleep` is interrupted 112
times, and **exactly one of those is a PendSV**:

    #1 exception 14 at pc 0x020022B2 _tx_thread_sleep+0xBA

The other 111 are SysTick (exception 15) at `_tx_thread_sleep+0x84`,
which is the caller-error guard path: once the flag is stuck, every later
sleep is refused there and returns instantly, and the timer keeps landing
on the spin. So the single PendSV is first in the window and the 111 are
its aftermath, which matches what the hotspot table showed from the other
side.

The companion run is the one that settles it:

    ra8_emulator threadx_blink.elf --ms 2000 --taken-in _tx_thread_system_suspend
    taken-in: _tx_thread_system_suspend @0x020022D8+0x230, 0 exception(s) taken inside

Zero. The suspend function is never interrupted at all, so nothing is
lost inside it. The whole loss happens in the caller.

### Where 0x020022B2 sits

    20022a6:  6013       str  r3, [r2, #0]     ; _tx_thread_preempt_disable = 1
    20022a8:  6b3b       ldr  r3, [r7, #48]
    20022aa:  60fb       str  r3, [r7, #12]
    20022ac:  68fb       ldr  r3, [r7, #12]
    20022ae:  f383 8810  msr  PRIMASK, r3      ; interrupts back on
    20022b2:  bf00       nop                   ; <-- PendSV taken here
    20022b4:  6af8       ldr  r0, [r7, #44]
    20022b6:  f000 f80f  bl   _tx_thread_system_suspend   ; would decrement

The flag goes up at 0x020022A6, interrupts come back on at 0x020022AE,
and the call that takes the flag down again is four instructions later at
0x020022B6. The PendSV lands on the first instruction of that window, on
the `nop`. The thread is switched out holding the flag at 1 and never
returns to make the call, so `tx_timer_interrupt.S:222` refuses to issue
a PendSV from then on and no thread is ever scheduled again.

### What this does NOT yet establish

Whether the emulator is wrong to take it there. ICSR.PENDSVSET is sticky,
so a PendSV pended **before** the flag went up and taken at the first
boundary where priority allows is legal hardware behaviour, and the
window at 0x020022AE-0x020022B6 is genuinely interruptible by design.
Two readings remain open and the next pass should separate them:

1. The model pended PendSV while `_tx_thread_preempt_disable` was already
   non-zero, which the timer path is supposed to refuse. That is a model
   bug in the timer handler and the fix is there.
2. The PendSV was pended legitimately before the increment, and the model
   is merely taking it at an instruction boundary that real silicon would
   not offer, most likely because a chunk boundary lets a pending
   exception in at a point hardware would have run through.

Reading 2 is the one to test first, because `--taken-in` already shows
the entry is the FIRST exception in the function across the whole run:
a systematically wrong boundary would be expected to strand more than one
sleep out of 452. A single strand looks like a rare coincidence of chunk
edge and window, not a standing rule.
