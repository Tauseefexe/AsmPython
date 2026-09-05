/* ============================================================================
 *  AsmPython  --  a from-scratch CPython clone in x86-64 assembly.
 *
 *  FILE    : src/objectproto.S
 *  PHASE   : 10 (SINGLETONS + COMPARISONS)
 *  PURPOSE : Add the immortal singleton objects None / True / False and the
 *            comparison operators (== != < >) that produce real bool results.
 *
 *  SINGLETONS
 *      In CPython, None, True and False are single forever-living objects.
 *      We provide them as statically-allocated PyObjects (refcount handled by
 *      a guarding dealloc, exactly like the small-int cache):
 *
 *          pym_None, pym_True, pym_False  -- immortal, type-checked instances
 *          pym_bool_type / pym_none_type  -- their type objects
 *
 *  COMPARISONS  (on ints for now)
 *      PyObject *asm_int_eq(PyObject *a, PyObject *b)   -> True/False
 *      PyObject *asm_int_ne(PyObject *a, PyObject *b)
 *      PyObject *asm_int_lt(PyObject *a, PyObject *b)
 *      PyObject *asm_int_gt(PyObject *a, PyObject *b)
 *
 *  ABI/ASSEMBLER : System V AMD64; GNU as Intel syntax.
 * ==========================================================================*/

    .intel_syntax noprefix

/* PyObject head offsets. */
    .equ PY_OFFSET_REFCNT,  0
    .equ PY_OFFSET_TYPE,    8
    .equ PY_OBJECT_SIZE,    16
    .equ PYM_INT_OFFSET_VALUE, 16

/* ============================================================================
 *  asm_bool_new -- return the immortal True/False singleton for a C truth.
 *  in: rdi = 0 or non-zero.  out: rax = &pym_True or &pym_False.
 *  (CPython-like truthiness helper; used by comparisons and later control flow.)
 * ==========================================================================*/
    .section .text

    .globl asm_bool_new
    .type  asm_bool_new, @function
asm_bool_new:
    test   rdi, rdi
    jz     .bfalse
    lea    rax, [rip + pym_True]
    ret
.bfalse:
    lea    rax, [rip + pym_False]
    ret
    .size asm_bool_new, . - asm_bool_new

/* --- fetch True/False value (1 or 0) for the singleton, for tests ---------- */
    .globl asm_bool_value
    .type  asm_bool_value, @function
asm_bool_value:
    lea    rax, [rip + pym_True]
    cmp    rdi, rax
    jne    .bv_false
    mov    eax, 1
    ret
.bv_false:
    xor    eax, eax
    ret
    .size asm_bool_value, . - asm_bool_value

/* --- asm_is_none : rax = 1 if obj IS None, else 0 -------------------------- */
    .globl asm_is_none
    .type  asm_is_none, @function
asm_is_none:
    lea    rax, [rip + pym_None]
    cmp    rdi, rax
    sete   al
    movzx  eax, al
    ret
    .size asm_is_none, . - asm_is_none

/* ============================================================================
 *  COMPARISON OPERATORS (ints -> bool singletons)
 *  Each takes (a in rdi, b in rsi); a and b are int objects. They read the
 *  payloads at +16, compare, and return &pym_True / &pym_False.
 * ==========================================================================*/

/* a == b */
    .globl asm_int_eq
    .type  asm_int_eq, @function
asm_int_eq:
    mov    rax, [rdi + PYM_INT_OFFSET_VALUE]
    mov    rcx, [rsi + PYM_INT_OFFSET_VALUE]
    cmp    rax, rcx
    sete   al
    movzx  eax, al
    mov    rdi, rax
    jmp    asm_bool_new               /* tail call                           */
    .size asm_int_eq, . - asm_int_eq

/* a != b */
    .globl asm_int_ne
    .type  asm_int_ne, @function
asm_int_ne:
    mov    rax, [rdi + PYM_INT_OFFSET_VALUE]
    mov    rcx, [rsi + PYM_INT_OFFSET_VALUE]
    cmp    rax, rcx
    setne  al
    movzx  eax, al
    mov    rdi, rax
    jmp    asm_bool_new
    .size asm_int_ne, . - asm_int_ne

/* a < b */
    .globl asm_int_lt
    .type  asm_int_lt, @function
asm_int_lt:
    mov    rax, [rdi + PYM_INT_OFFSET_VALUE]
    cmp    rax, [rsi + PYM_INT_OFFSET_VALUE]
    setl   al
    movzx  eax, al
    mov    rdi, rax
    jmp    asm_bool_new
    .size asm_int_lt, . - asm_int_lt

/* a > b */
    .globl asm_int_gt
    .type  asm_int_gt, @function
asm_int_gt:
    mov    rax, [rdi + PYM_INT_OFFSET_VALUE]
    cmp    rax, [rsi + PYM_INT_OFFSET_VALUE]
    setg   al
    movzx  eax, al
    mov    rdi, rax
    jmp    asm_bool_new
    .size asm_int_gt, . - asm_int_gt

/* ---- boolean negation: not obj (truthy -> False) --------------------------
 *   Truthiness: True and any non-zero int are True; False, None and zero are
 *   False. Returns the bool singleton.                                       */
    .globl asm_int_not
    .type  asm_int_not, @function
asm_int_not:
    lea    rax, [rip + pym_True]
    cmp    rdi, rax
    je     .nnot                  /* True -> False                          */
    lea    rax, [rip + pym_False]
    cmp    rdi, rax
    je     .not_not               /* False -> True                          */
    /* an int: nonzero is truthy */
    mov    rax, [rdi + PYM_INT_OFFSET_VALUE]
    test   rax, rax
    jz     .not_not               /* 0 -> True (not False)                  */
    /* nonzero int -> not -> False */
    lea    rax, [rip + pym_False]
    ret
.not_not:
    lea    rax, [rip + pym_True]
    ret
.nnot:
    lea    rax, [rip + pym_False]
    ret
    .size asm_int_not, . - asm_int_not

/* ============================================================================
 *  THE SINGLETON OBJECTS + TYPE OBJECTS
 * ==========================================================================*/
    .section .rodata
pym_none_type_name:
    .asciz "NoneType"
pym_bool_type_name:
    .asciz "bool"

    .section .data
    .balign 16
    .globl pym_none_type
pym_none_type:
    .quad pym_none_type_name
    .quad asm_immortal_dealloc        /* None is immortal                    */
    .quad PY_OBJECT_SIZE

    .globl pym_bool_type
pym_bool_type:
    .quad pym_bool_type_name
    .quad asm_immortal_dealloc        /* True/False immortal                 */
    .quad PY_OBJECT_SIZE

/* The immortal singleton objects. */
    .balign 16
    .globl pym_None
pym_None:
    .quad 1                          /* ob_refcnt                            */
    .quad pym_none_type               /* ob_type                              */

    .globl pym_False
pym_False:
    .quad 1
    .quad pym_bool_type

    .globl pym_True
pym_True:
    .quad 1
    .quad pym_bool_type

/* ----------------------------------------------------------------------------
 *  asm_immortal_dealloc -- type->dealloc for singletons: do nothing.
 * ------------------------------------------------------------------------- */
    .section .text
    .globl asm_immortal_dealloc
    .type  asm_immortal_dealloc, @function
asm_immortal_dealloc:
    ret
    .size asm_immortal_dealloc, . - asm_immortal_dealloc

/* Keep the heap page non-executable. */
    .section .note.GNU-stack,"",@progbits
