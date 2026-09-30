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

## What is open

Why `_tx_thread_preempt_disable` latches. ThreadX increments it around
suspend and resume and drops it again at the end of its preempt check, so a
latch at 1 means the model reaches the increment and never the matching
decrement. The two things worth reading first are the PendSV path out of
`_tx_thread_system_return` and whether the preempt check runs to its end at
all; `where:` already shows PendSV_Handler as a live sample site in other
images, so PendSV is taken in general and the question is this path.

The boot burst may well be the same story one step earlier, since a thread
running with a null `current_ptr` is the dispatcher having gone only half way.
Do not assume they are one fix until the second is shown.
