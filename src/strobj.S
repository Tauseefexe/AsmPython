/* ============================================================================
 *  AsmPython  --  a from-scratch CPython clone in x86-64 assembly.
 *
 *  FILE    : src/strobj.S
 *  PHASE   : 9  (THE "str" TYPE -- byte-string objects)
 *  PURPOSE : Give the runtime real text. This phase adds immutable byte-string
 *            objects so source like print("hello") has something concrete to
 *            hold and print. Layout mirrors CPython's compact representation:
 *            a PyObject head followed inline by the bytes (no separate heap
 *            block, so a string is one contiguous allocation).
 *
 *  PyStr layout (offsets MUST match include/asmpython.h):
 *      +0  ob_refcnt   (uint64)  -- PyObject head
 *      +8  ob_type     (uint64)  -- -> pym_str_type
 *      +16 length      (uint64)  -- number of payload bytes
 *      +24 data[length]          -- inline payload bytes (little-endian text)
 *      ... data[length] = '\0'   -- NUL terminator kept for easy C interop
 *
 *  ROUTINES:
 *      PyObject *asm_str_new(const char *bytes, uint64_t len);
 *          allocate a compact string object and copy `len` bytes in.
 *
 *      void asm_str_dealloc(PyObject *op);
 *          str's type->dealloc slot. The compact block is arena-backed, so we
 *          simply zero the header to neutralise stale references (memory is
 *          reclaimed at arena level in a later phase).
 *
 *      void asm_print_string_object(PyObject *str_obj);
 *          write a string object's payload bytes to stdout (no newline).
 *
 *  ABI/ASSEMBLER : System V AMD64; GNU as Intel syntax.
 * ==========================================================================*/

    .intel_syntax noprefix

/* Layout shared with the C header and the VM printer. */
    .equ PY_OFFSET_REFCNT,  0
    .equ PY_OFFSET_TYPE,    8
    .equ PYM_STR_OFFSET_LENGTH, 16
    .equ PYM_STR_OFFSET_DATA,   24
    .equ PYM_STR_HEADER,        24      /* bytes of header before data      */
    .equ PYM_STR_BASIC,         24      /* nominal basic_size (>= header)   */

/* ============================================================================
 *  1.  asm_str_new -- build a compact string object
 *      PyObject *asm_str_new(const char *bytes in rdi, uint64_t len in rsi)
 * ----------------------------------------------------------------------------
 *   Registers: rbx = bytes, r12 = len (both saved, survive asm_raw_alloc).
 * ==========================================================================*/
    .section .text

    .globl asm_str_new
    .type  asm_str_new, @function
asm_str_new:
    push   rbx
    push   r12
    push   r13
    mov    rbx, rdi                  /* bytes source                         */
    mov    r12, rsi                  /* length                               */

    /* total footprint = header + len + 1 (NUL), rounded up to 16 */
    lea    rdi, [r12 + PYM_STR_HEADER + 1]
    lea    rdi, [rdi + 15]
    and    rdi, -16
    call   asm_raw_alloc             /* rax = aligned block                   */
    test   rax, rax
    jz     .snew_oom

    mov    qword ptr [rax + PY_OFFSET_REFCNT], 1
    lea    rcx, [rip + pym_str_type]
    mov    [rax + PY_OFFSET_TYPE], rcx
    mov    [rax + PYM_STR_OFFSET_LENGTH], r12

    /* copy len bytes from [rbx] to [rax + header] */
    lea    rdi, [rax + PYM_STR_OFFSET_DATA]
    mov    r13, r12                  /* counter                              */
    test   r13, r13
    jz     .snew_copy_done
.snew_copy:
    mov    dl, [rbx]
    mov    [rdi], dl
    inc    rbx
    inc    rdi
    dec    r13
    jnz    .snew_copy
.snew_copy_done:
    mov    byte ptr [rdi], 0         /* NUL terminator                       */

    pop    r13
    pop    r12
    pop    rbx
    ret
.snew_oom:
    xor    eax, eax
    pop    r13
    pop    r12
    pop    rbx
    ret
    .size asm_str_new, . - asm_str_new

/* ----------------------------------------------------------------------------
 *  2.  asm_str_dealloc -- neutralize a string object's header
 * ------------------------------------------------------------------------- */
    .globl asm_str_dealloc
    .type  asm_str_dealloc, @function
asm_str_dealloc:
    mov    qword ptr [rdi + PY_OFFSET_REFCNT], 0
    mov    qword ptr [rdi + PY_OFFSET_TYPE], 0
    ret
    .size asm_str_dealloc, . - asm_str_dealloc

/* ----------------------------------------------------------------------------
 *  3.  asm_print_string_object -- write payload to stdout (no newline)
 *      void asm_print_string_object(PyObject *str_obj in rdi)
 * ------------------------------------------------------------------------- */
    .globl asm_print_string_object
    .type  asm_print_string_object, @function
asm_print_string_object:
    mov    rsi, rdi
    mov    rdx, [rsi + PYM_STR_OFFSET_LENGTH]
    lea    rsi, [rsi + PYM_STR_OFFSET_DATA]  /* buf = obj + data offset     */
    jmp    asm_write_stdout          /* tail call (len in rdx)                */
    .size asm_print_string_object, . - asm_print_string_object

/* ----------------------------------------------------------------------------
 *  4.  the "str" type object + name
 * ------------------------------------------------------------------------- */
    .section .data
    .balign 16
    .globl pym_str_type
pym_str_type:
    .quad pym_str_type_name          /* +0  name                             */
    .quad asm_str_dealloc            /* +8  dealloc                          */
    .quad PYM_STR_BASIC              /* +16 basic_size                       */

    .section .rodata
pym_str_type_name:
    .asciz "str"

/* Keep the heap page non-executable. */
    .section .note.GNU-stack,"",@progbits
