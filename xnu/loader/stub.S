/*
 * Local smoke-test stub: stands in for XNU so the loader's segment placement
 * and boot_args handover can be observed on a real emulator without the built
 * kernel. Not part of the product, not committed.
 */
    .text
    .global _start
_start:
    /* boot_args.physBase is at offset 16; the plan must have used RAM's base. */
    ldr     x4, [x0, #16]
    movz    x5, #0x4000, lsl #16
    cmp     x4, x5

    adr     x19, msg_ok
    mov     x20, #(msg_ok_end - msg_ok)
    b.eq    report

    adr     x19, msg_bad
    mov     x20, #(msg_bad_end - msg_bad)

report:
    movz    x21, #0x0900, lsl #16       /* PL011 data register */
loop:
    cbz     x20, done
    ldrb    w22, [x19], #1
    str     w22, [x21]
    sub     x20, x20, #1
    b       loop

done:
    wfi
    b       done

msg_ok:
    .ascii  "ONELXNU stub: loader placed the segment and passed boot_args\n"
msg_ok_end:
msg_bad:
    .ascii  "ONELXNU stub: x0 did not point at the planned boot_args\n"
msg_bad_end:
