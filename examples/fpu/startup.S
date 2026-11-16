.syntax unified
.thumb
.section .isr_vector,"a",%progbits
.word 0x2219fff8
.word Reset_Handler
.section .text.Reset_Handler,"ax",%progbits
.global Reset_Handler
.type Reset_Handler,%function
.thumb_func
Reset_Handler:
    ldr r0, =0xE000ED88
    ldr r1, [r0]
    orr r1, r1, #0x00F00000
    str r1, [r0]
    dsb
    isb
    bl main
1:  b 1b
.size Reset_Handler, .-Reset_Handler
.ltorg
