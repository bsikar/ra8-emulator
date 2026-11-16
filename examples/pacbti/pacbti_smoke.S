.syntax unified
.thumb

.section .text.worker,"ax",%progbits
.type worker,%function
.thumb_func
worker:
    bti
    movw r0, #0x247
    bx lr
.size worker, .-worker

.section .text.main,"ax",%progbits
.global main
.type main,%function
.thumb_func
main:
    pacbti r12, lr, sp
    push.w {r0, r1, r12, lr}
    ldr r3, =worker
    str r3, [sp, #4]
    ldr r3, [sp, #4]
    blx r3
    mov.w r3, #0x22000000
    str r0, [r3]
    add sp, #8
    pop.w {r12, lr}
    aut r12, lr, sp
    bx lr
.ltorg
.size main, .-main
