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
    movs r0, #0x50
    msr control, r0
    isb
    bl main
1:  b 1b
.size Reset_Handler, .-Reset_Handler
