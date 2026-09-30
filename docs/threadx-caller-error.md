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
