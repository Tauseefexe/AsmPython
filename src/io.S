/* ============================================================================
 *  AsmPython  --  a from-scratch CPython clone in x86-64 assembly.
 *
 *  FILE    : src/io.S
 *  PHASE   : 6  (OUTPUT LAYER / seed of print())
 *  PURPOSE : Give the runtime eyes and a mouth. Every program eventually has
 *            to emit bytes, so this file implements integer->decimal
 *            formatting and a blocking write to file descriptor 1 (stdout).
 *            This is the platform-specific surface for output -- the whole
 *            runtime prints through these few routines, so a future Windows
 *            port replaces ONLY here (WriteFile instead of the write syscall).
 *
 *  ROUTINES:
 *      uint64_t asm_i64_to_ascii(int64_t value, char *dst);
 *          Format `value` as a NUL-free decimal string into `dst`
 *          (handling the sign and INT64_MIN). Returns the byte length.
 *          Pure -- no I/O -- fully unit-testable.
 *
 *      uint64_t asm_write_stdout(const char *buf, uint64_t len);
 *          Write all `len` bytes to fd 1, looping over partial writes.
 *          Returns total bytes written (or a negative errno on failure).
 *
 *      void     asm_print_int_object(PyObject *int_obj);
 *          Format the int payload of an object and write it to stdout.
 *          (int payload lives at [obj + 16], see intobj.S.)
 *
 *      void     asm_print_newline(void);
 *          Emit a single '\n'.
 *
 *  ABI/ASSEMBLER : System V AMD64; GNU as Intel syntax.
 * ==========================================================================*/

    .intel_syntax noprefix

/* Linux x86-64 syscall + fd constants (see <sys/syscall.h>, <unistd.h>). */
    .equ SYS_WRITE,  1
    .equ SYS_EXIT,  60                       /* reserved for the future shell */
    .equ FD_STDOUT,  1

/* The int object's payload word (matches src/intobj.S). */
    .equ PYM_INT_OFFSET_VALUE, 16

/* ============================================================================
 *  1.  asm_i64_to_ascii -- signed 64-bit integer to decimal bytes
 *      uint64_t asm_i64_to_ascii(int64_t value in rdi, char *dst in rsi)
 * ----------------------------------------------------------------------------
 *   Method: strip the sign (handling the two's-complement extreme INT64_MIN
 *   by treating the negated value as an unsigned magnitude), generate digits
 *   least-significant-first into a stack scratch area, then copy them MSD-first
 *   into `dst`. Register map (no calls are made, so no callee-saved register
 *   needs to be pushed):
 *       rax   : running quotient (value)          r8 : divisor (10)
 *       rdx   : remainder / byte temp             rcx : back-fill cursor
 *       rsi   : destination (kept whole time)     r9 : digit count
 *       r10   : negative flag (0/1)               r11 : copy count
 * ==========================================================================*/
    .section .text

    .globl asm_i64_to_ascii
    .type  asm_i64_to_ascii, @function
asm_i64_to_ascii:
    mov    rax, rdi                  /* rax = value                           */
    xor    r10d, r10d                /* r10 = negative flag = 0               */
    test   rax, rax
    jns    .A_pos
    mov    r10d, 1                   /* flag: print a leading '-'              */
    neg    rax                       /* rax = |value|; INT64_MIN wraps to its  */
                                     /* unsigned magnitude 2^63 -- correct     */
.A_pos:
    sub    rsp, 40                   /* 40-byte scratch area (>= 21 needed)    */
    lea    rcx, [rsp + 31]           /* cursor writes digits downward          */
    mov    r8,  10
    xor    r9d, r9d                  /* r9 = digit count                       */
.A_digits:
    xor    edx, edx
    div    r8                        /* rax/=10, rdx = remainder (0..9)        */
    add    dl, 0x30                  /* digit -> ASCII '0'..'9'                */
    mov    [rcx], dl                 /* store this (less-significant) digit    */
    dec    rcx
    inc    r9
    test   rax, rax
    jnz    .A_digits

    /* rcx+1 now points at the most-significant digit. */
    lea    rdi, [rcx + 1]            /* rdi = source start                     */
    test   r10d, r10d
    jz     .A_copy
    mov    byte ptr [rcx], '-'       /* prepend the sign                       */
    mov    rdi, rcx                  /* source now includes the '-'            */
    inc    r9                        /* +1 char                                */
.A_copy:
    mov    r11, r9                   /* r11 = byte count to copy               */
    mov    rax, r11                  /* rax = return length                    */
    test   r11, r11
    jz     .A_done
.A_copy_loop:
    mov    dl, [rdi]
    mov    [rsi], dl
    inc    rdi
    inc    rsi
    dec    r11
    jnz    .A_copy_loop
.A_done:
    add    rsp, 40
    ret
    .size asm_i64_to_ascii, . - asm_i64_to_ascii

/* ----------------------------------------------------------------------------
 *  2.  asm_write_stdout -- write every byte (looping past partial writes)
 *      uint64_t asm_write_stdout(const char *buf in rsi, uint64_t len in rdx)
 * ----------------------------------------------------------------------------
 *   Register map:
 *       r9  : running total            rsi : current buffer position
 *       rdx : remaining byte count      (kernel preserves rsi/rdx across the
 *       rdi : fd (1)                    syscall; only rcx and r11 are clobbered)
 * ------------------------------------------------------------------------- */
    .globl asm_write_stdout
    .type  asm_write_stdout, @function
asm_write_stdout:
    xor    r9d, r9d                  /* total bytes written = 0                */
    test   rdx, rdx
    jz     .W_out                    /* nothing to write                       */
.W_loop:
    mov    eax, SYS_WRITE            /* syscall number                         */
    mov    edi, FD_STDOUT            /* arg1: fd = stdout                      */
    syscall                          /* rsi=buf, rdx=remaining; -> rax=bytes   */
    test   rax, rax
    js     .W_err                    /* negative => errno, propagate it        */
    add    r9, rax                   /* accumulate                             */
    add    rsi, rax                  /* advance buffer                         */
    sub    rdx, rax                  /* shrink remaining                        */
    jnz    .W_loop                   /* keep going until all bytes are sent    */
.W_out:
    mov    rax, r9
    ret
.W_err:
    mov    rax, -1                   /* surface a write error as a sentinel    */
    ret
    .size asm_write_stdout, . - asm_write_stdout

/* ----------------------------------------------------------------------------
 *  3.  asm_print_int_object -- print the integer stored in an int object
 *      void asm_print_int_object(PyObject *int_obj in rdi)
 * ------------------------------------------------------------------------- */
    .globl asm_print_int_object
    .type  asm_print_int_object, @function
asm_print_int_object:
    push   rbx                       /* entry rsp%16==8 -> push -> ==0        */
    mov    rbx, rdi                  /* rbx = object (survives the calls)     */
    mov    rax, [rbx + PYM_INT_OFFSET_VALUE]  /* rax = int payload value      */
    lea    rsi, [rip + pym_outbuf]
    mov    rdi, rax
    call   asm_i64_to_ascii          /* format into the shared out buffer      */
    mov    rdx, rax                  /* rdx = length                           */
    lea    rsi, [rip + pym_outbuf]
    call   asm_write_stdout
    pop    rbx
    ret
    .size asm_print_int_object, . - asm_print_int_object

/* ----------------------------------------------------------------------------
 *  4.  asm_print_newline -- emit a single '\n'
 * ------------------------------------------------------------------------- */
    .globl asm_print_newline
    .type  asm_print_newline, @function
asm_print_newline:
    lea    rsi, [rip + pym_newline]
    mov    edx, 1
    jmp    asm_write_stdout          /* tail call (rdi/fd set inside)          */
    .size asm_print_newline, . - asm_print_newline

/* ============================================================================
 *  5.  SHARED OUTPUT STATE
 *      pym_outbuf : reusable scratch where numbers are formatted before write.
 *      pym_newline: the single newline byte (read-only).
 * ==========================================================================*/
    .section .bss
    .balign 16
pym_outbuf:
    .zero 64                         /* room for '-' + 20 digits + padding    */

    .section .rodata
pym_newline:
    .byte 0x0A                       /* '\n'                                  */

/* Keep the heap page non-executable. */
    .section .note.GNU-stack,"",@progbits
