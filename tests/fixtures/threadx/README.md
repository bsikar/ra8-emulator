`threadx_stkof.elf` is the ThreadX stack-overflow image from ra8-firmware
(`examples/ek_ra8d2/hil_needs_revalidation/threadx_stkof`, RA8FW-503), built at
ra8-firmware `26bd698` and stripped of debug sections. It is the RA8EMU-243
fixture: the stack-limit check has to catch a real ThreadX thread overflowing
its stack.

The image runs on CPU0. It creates one thread with a 1 KiB stack and recurses in
it until the stack runs out. The ThreadX port loads PSPLIM from the thread's
stack start, so the overflow raises a UsageFault with UFSR.STKOF. The image's
handler passes that fault to ThreadX's stack-error handler, and the registered
callback prints the result on the SCI console:

```
stkof: start
stkof: thread=overflow caught
stkof: PASS
```

If the recursion returns without a fault, the image prints `stkof: FAIL`
instead.

Rebuild from ra8-firmware with Arm GNU 13.3.rel1 on `PATH`:

```sh
zig build arm
arm-none-eabi-strip -g -o threadx_stkof.elf zig-out/arm/threadx_stkof.elf
```
