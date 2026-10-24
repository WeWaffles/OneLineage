/*
 * OneLineage loader for the ONELXNU payload (QEMU development only).
 *
 * QEMU enters this image at loader_addr with the MMU, both caches and the
 * stack off. It is position independent: every address it needs comes from
 * loader_params, the 48-byte block at the end of this image, which
 * tools/xnu/loader.py patches from the boot plan before the image is used.
 * Nothing is computed here that the plan already decided, so the layout has
 * exactly one implementation.
 *
 * What it does, in order:
 *   1. check that loader_params was actually patched;
 *   2. check the payload's ONELXNU header, and that its phys_base agrees with
 *      the address the plan loaded it at;
 *   3. copy each segment from payload + fileoff to
 *      phys_base + (vmaddr - virtual_base);
 *   4. zero the difference between filesize and vmsize, which is where the
 *      kernel's .bss lives;
 *   5. put boot_args in x0, the stack top in sp, and branch to the entry
 *      address expressed physically, because the MMU is still off.
 *
 * Any failure prints one line to the PL011 at 0x09000000. That address is the
 * same one the qemu profile of the kernel writes to, so a loader rejection is
 * distinguishable from "the kernel printed nothing".
 *
 * Assemble with clang for an aarch64 ELF target, then extract .text with
 * tools/xnu/extract_elf.py. See xnu/README.md.
 */

    .equ UART_DR,        0x09000000

    .equ PARAMS_MAGIC,   0
    .equ PARAMS_VERSION, 8
    .equ PARAMS_BOOT_ARGS, 16
    .equ PARAMS_STACK_TOP, 24
    .equ PARAMS_ENTRY,   32
    .equ PARAMS_PAYLOAD, 40

    .equ HDR_MAGIC,        0
    .equ HDR_VERSION,      8
    .equ HDR_SEGMENTS,     12
    .equ HDR_VIRTUAL_BASE, 16
    .equ HDR_PHYS_BASE,    56
    .equ SEGMENT_TABLE,    680      /* 0x48 command line + 608 bytes */
    .equ SEGMENT_STRIDE,   32
    .equ ONELXNU_VERSION,  1

    .text
    .balign 16
    .global _start
    .type _start, %function

_start:
    /* x20 = our own parameter block. The reference goes through the local
     * .Lparams label so the assembler resolves it here: a reference to the
     * global loader_params would leave a relocation, and an unlinked image
     * would carry zero immediates instead of an address. */
    adrp    x20, .Lparams
    add     x20, x20, :lo12:.Lparams

    /* 1. loader_params must carry the magic loader.py writes. */
    ldr     x1, [x20, #PARAMS_MAGIC]
    movz    x2, #0x4e4f                 /* "ON" */
    movk    x2, #0x4c45, lsl #16        /* "EL" */
    movk    x2, #0x5041, lsl #32        /* "PA" */
    movk    x2, #0x4d52, lsl #48        /* "RM" */
    cmp     x1, x2
    b.ne    fail_params

    ldr     x21, [x20, #PARAMS_BOOT_ARGS]
    ldr     x22, [x20, #PARAMS_STACK_TOP]
    ldr     x23, [x20, #PARAMS_ENTRY]
    ldr     x24, [x20, #PARAMS_PAYLOAD]

    /* 2. The payload header must be ONELXNU version 1. */
    ldr     x1, [x24, #HDR_MAGIC]
    movz    x2, #0x4e4f                 /* "ON" */
    movk    x2, #0x4c45, lsl #16        /* "EL" */
    movk    x2, #0x584e, lsl #32        /* "XN" */
    movk    x2, #0x0055, lsl #48        /* "U\0" */
    cmp     x1, x2
    b.ne    fail_payload

    ldr     w3, [x24, #HDR_VERSION]
    cmp     w3, #ONELXNU_VERSION
    b.ne    fail_payload

    ldr     w25, [x24, #HDR_SEGMENTS]
    cbz     w25, fail_payload

    ldr     x26, [x24, #HDR_VIRTUAL_BASE]
    ldr     x27, [x24, #HDR_PHYS_BASE]
    /* A payload loaded at the wrong address would scatter the kernel over
     * unrelated RAM, so refuse rather than guess. */
    cmp     x27, x24
    b.ne    fail_payload

    mov     x28, x24
    add     x28, x28, #SEGMENT_TABLE
    mov     x9, #0

segment_loop:
    cmp     x9, x25
    b.hs    segments_done

    lsl     x10, x9, #5                 /* 32 bytes per table entry */
    add     x10, x28, x10
    ldr     x11, [x10, #0]              /* vmaddr */
    ldr     x12, [x10, #8]              /* vmsize */
    ldr     x13, [x10, #16]             /* fileoff */
    ldr     x14, [x10, #24]             /* filesize */

    sub     x15, x11, x26               /* + phys_base = physical destination */
    add     x15, x15, x27
    add     x16, x24, x13               /* payload + fileoff */
    mov     x17, x14                    /* bytes left to copy */

copy_words:
    cmp     x17, #8
    b.lo    copy_bytes
    ldr     x18, [x16], #8
    str     x18, [x15], #8
    sub     x17, x17, #8
    b       copy_words

copy_bytes:
    cbz     x17, zero_bss
    ldrb    w18, [x16], #1
    strb    w18, [x15], #1
    sub     x17, x17, #1
    b       copy_bytes

zero_bss:
    /* x15 already points at destination + filesize. A vmsize below filesize
     * cannot happen (the packer keeps only mapped segments), but sub underflow
     * would become a multi-gigabyte store loop, so it is checked. */
    subs    x17, x12, x14
    b.ls    segment_next

zero_words:
    cmp     x17, #8
    b.lo    zero_bytes
    str     xzr, [x15], #8
    sub     x17, x17, #8
    b       zero_words

zero_bytes:
    cbz     x17, segment_next
    strb    wzr, [x15], #1
    sub     x17, x17, #1
    b       zero_bytes

segment_next:
    add     x9, x9, #1
    b       segment_loop

segments_done:
    /* Caches are off at entry, so the stores above are already visible to
     * instruction fetch. dsb/isb make that ordering explicit rather than
     * assumed, and neither needs a cache maintenance instruction that would
     * depend on which exception level QEMU started us at. */
    dsb     sy
    isb

    /* 5. Hand over exactly what iBoot would: boot_args in x0. */
    mov     x0, x21
    mov     x1, xzr
    mov     x2, xzr
    mov     x3, xzr
    mov     sp, x22
    br      x23

fail_params:
    adr     x5, msg_params
    mov     x6, #(msg_params_end - msg_params)
    b       uart_report

fail_payload:
    adr     x5, msg_payload
    mov     x6, #(msg_payload_end - msg_payload)
    b       uart_report

/* x5 = bytes, x6 = length. Clobbers x4, x5, x6, x7. */
uart_report:
    movz    x4, #0x0900, lsl #16        /* PL011 data register */
uart_loop:
    cbz     x6, halt
    ldrb    w7, [x5], #1
    str     w7, [x4]
    subs    x6, x6, #1
    b.ne    uart_loop

halt:
    wfi
    b       halt

msg_params:
    .ascii  "ONELXNU loader: parameter block was not patched\n"
msg_params_end:

msg_payload:
    .ascii  "ONELXNU loader: payload header is not ONELXNU v1\n"
msg_payload_end:

/*
 * Patched by tools/xnu/loader.py. The magic is left zero so an unpatched image
 * is rejected instead of jumping somewhere arbitrary.
 */
    .balign 64
    .global loader_params
    .type loader_params, %object
loader_params:
.Lparams:
    .quad 0                             /* magic, becomes "ONELPARM" */
    .quad 0                             /* version 1 in the low word */
    .quad 0                             /* boot_args physical address */
    .quad 0                             /* stack top */
    .quad 0                             /* kernel entry, physical */
    .quad 0                             /* payload physical address */
    .size loader_params, . - loader_params

    .balign 16
