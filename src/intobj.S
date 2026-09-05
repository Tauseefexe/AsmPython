/* ============================================================================
 *  AsmPython  --  a from-scratch CPython clone in x86-64 assembly.
 *
 *  FILE    : src/intobj.S
 *  PHASE   : 4  (CONCRETE BUILT-IN TYPE: int + CPython small-int cache)
 *  PURPOSE : Introduce the first concrete value type. This mirrors CPython's
 *            behaviour exactly:
 *
 *              * the integer -5 .. 256 are pre-created at startup and are
 *                IMMORTAL singletons (CPython's small-int cache); asking for
 *                one always returns the SAME object;
 *              * every other integer is a freshly allocated, reference-counted
 *                object that is recycled when its refcount reaches zero.
 *
 *            Object layout -- a "PyInt" is a PyObject head plus an int64 value:
 *                +0  ob_refcnt     (int64)
 *                +8  ob_type       (-> pym_int_type)
 *                +16 value         (int64)   -- our extra payload word
 *
 *  ROUTINES:
 *      PyObject *asm_int_new(int64_t value);
 *          return value as a PyObject with a fresh reference:
 *            cached  -5..256  -> the matching immortal singleton (incref'd)
 *            otherwise        -> a fresh recycled int object with `value`
 *
 *      void      asm_int_dealloc(PyObject *op);
 *          int's type->dealloc slot. If `op` is one of the cached singletons
 *          it is IMMORTAL and we return without freeing; otherwise the slot is
 *          returned to the size-class free list.
 *
 *      int64_t   asm_int_get_value(PyObject *op);
 *          read back the stored value (for arithmetic + tests).
 *
 *  ABI/ASSEMBLER : System V AMD64; GNU as Intel syntax.
 * ==========================================================================*/

    .intel_syntax noprefix

/* Layout shared with pyobject.S / refcount.S. */
    .equ PY_OFFSET_REFCNT,       0
    .equ PY_OFFSET_TYPE,         8
    .equ PYM_INT_OFFSET_VALUE,  16      /* payload value lives at +16          */

/* The int type's footprint and small-int cache geometry. */
    .equ PYM_INT_SIZE,          24      /* sizeof(PyInt) = 16 head + 8 value   */
    .equ PYM_INT_MIN,           -5      /* smallest cached integer             */
    .equ PYM_INT_MAX,           256     /* largest  cached integer             */
    .equ PYM_INT_CACHE_COUNT,   262     /* 256 - (-5) + 1                      */
    .equ PYM_INT_CACHE_BYTES,   6288    /* COUNT * SIZE                        */

/* ============================================================================
 *  1.  REGISTER AND MEMORY MAP
 * ----------------------------------------------------------------------------
 *   asm_int_new(value)          in rdi; out rax (obj) or 0
 *       rbx = value (saved), r12 = (alignment). Cached look-up is a direct
 *       base + (value - MIN)*SIZE index into the static array -- O(1), no
 *       scan. Fresh ints go through asm_pyobject_new (size-class aware).
 *
 *   asm_int_dealloc(op)         in rdi; no return
 *       pure range test against [pym_smallint_cache, base + CACHE_BYTES);
 *       nothing else. Falls through to asm_pyobject_free for arena objects.
 *
 *   Static data:
 *       pym_int_type            the "int" PyTypeObject (name/dealloc/basic_size)
 *       pym_smallint_cache      CACHE_COUNT packed PyInt singletons (24 B each)
 * ==========================================================================*/

    .section .text

/* ----------------------------------------------------------------------------
 * 2.  asm_int_new -- fetch (or build) an int object holding `value`
 * ------------------------------------------------------------------------- */
    .globl asm_int_new
    .type  asm_int_new, @function
asm_int_new:
    push   rbx
    push   r12                       /* entry rsp%16==8 -> 2 pushes -> 0      */
    mov    rbx, rdi                  /* rbx = value (saved across the call)   */

    /* ---- CACHED RANGE?  -5 <= value <= 256 ------------------------------ */
    cmp    rdi, PYM_INT_MIN
    jl     .int_fresh                /* value < -5  -> a real object          */
    cmp    rdi, PYM_INT_MAX
    jg     .int_fresh                /* value > 256 -> a real object          */

    /* O(1) pointer to the singleton: base + (value - MIN) * SIZE            */
    lea    rax, [rip + pym_smallint_cache]
    lea    rcx, [rdi - PYM_INT_MIN]  /* rcx = index (0..261)                  */
    imul   rcx, rcx, PYM_INT_SIZE
    add    rax, rcx                  /* rax = &singleton                      */

    /* Each returned reference is accounted for (incref).                   */
    mov    rdx, [rax + PY_OFFSET_REFCNT]
    inc    rdx
    mov    [rax + PY_OFFSET_REFCNT], rdx

    pop    r12
    pop    rbx
    ret

    /* ---- FRESH: allocate a recycled/arena int object --------------------- */
.int_fresh:
    lea    rdi, [rip + pym_int_type]
    call   asm_pyobject_new          /* rax = object (type->basic_size=24)    */
    test   rax, rax
    jz     .int_oom
    mov    [rax + PYM_INT_OFFSET_VALUE], rbx   /* store our payload value     */
    pop    r12
    pop    rbx
    ret

.int_oom:
    xor    eax, eax
    pop    r12
    pop    rbx
    ret
    .size asm_int_new, . - asm_int_new

/* ----------------------------------------------------------------------------
 * 3.  asm_int_dealloc -- int's destructor (immortal cache, else free)
 * ------------------------------------------------------------------------- */
    .globl asm_int_dealloc
    .type  asm_int_dealloc, @function
asm_int_dealloc:
    lea    rax, [rip + pym_smallint_cache]
    lea    rcx, [rax + PYM_INT_CACHE_BYTES]
    cmp    rdi, rax
    jb     .dealloc_free             /* below cache -> a real (arena) object  */
    cmp    rdi, rcx
    jae    .dealloc_free             /* above cache -> a real (arena) object  */
    ret                              /* inside cache -> immortal, do nothing  */

.dealloc_free:
    jmp    asm_pyobject_free         /* tail call; rdi is still the object    */
    .size asm_int_dealloc, . - asm_int_dealloc

/* ----------------------------------------------------------------------------
 * 4.  asm_int_get_value -- read an int's payload
 * ------------------------------------------------------------------------- */
    .globl asm_int_get_value
    .type  asm_int_get_value, @function
asm_int_get_value:
    mov    rax, [rdi + PYM_INT_OFFSET_VALUE]
    ret
    .size asm_int_get_value, . - asm_int_get_value

/* ----------------------------------------------------------------------------
 * 6.  asm_int_add / asm_int_sub -- int arithmetic with small-int caching
 * ----------------------------------------------------------------------------
 *   Binary operators follow CPython's semantics: they take ownership of
 *   nothing (the operands' references belong to the caller), and they return a
 *   NEW reference to the result. Because the result is produced through
 *   asm_int_new(), any sum/difference that lands in -5..256 transparently
 *   becomes one of the immortal cache singletons -- e.g. `2 + 3` is literally
 *   the same object as `5`.
 * ------------------------------------------------------------------------- */
    .globl asm_int_add
    .type  asm_int_add, @function
asm_int_add:
    push   rbx
    push   r12                       /* entry rsp%16==8 -> 2 pushes -> 0      */
    mov    rbx, [rdi + PYM_INT_OFFSET_VALUE]  /* rbx = a.value                */
    mov    r12, [rsi + PYM_INT_OFFSET_VALUE]  /* r12 = b.value                */
    add    rbx, r12                            /* rbx = a.value + b.value     */
    mov    rdi, rbx                            /* arg1 = the sum              */
    call   asm_int_new                         /* rax = result object         */
    pop    r12
    pop    rbx
    ret
    .size asm_int_add, . - asm_int_add

    .globl asm_int_sub
    .type  asm_int_sub, @function
asm_int_sub:
    push   rbx
    push   r12
    mov    rbx, [rdi + PYM_INT_OFFSET_VALUE]   /* rbx = a.value               */
    mov    r12, [rsi + PYM_INT_OFFSET_VALUE]   /* r12 = b.value               */
    sub    rbx, r12                            /* rbx = a.value - b.value     */
    mov    rdi, rbx
    call   asm_int_new
    pop    r12
    pop    rbx
    ret
    .size asm_int_sub, . - asm_int_sub

/* ============================================================================
 * 5.  STATIC DATA -- the "int" type object + the small-int cache
 * ----------------------------------------------------------------------------
 *   The cache is emitted with a GAS macro so all 262 singletons are laid out
 *   correctly (refcnt=1, type=&pym_int_type, value = idx - 5).
 * ==========================================================================*/
    .section .rodata
pym_int_type_name:
    .asciz "int"

    .section .data
    .balign 16
    .globl pym_int_type
pym_int_type:
    .quad pym_int_type_name          /* +0  name        -> "int"              */
    .quad asm_int_dealloc            /* +8  dealloc     -> immortal-aware free*/
    .quad PYM_INT_SIZE               /* +16 basic_size  -> 24 bytes           */

    .balign 16
    .globl pym_smallint_cache
pym_smallint_cache:
    .set pym_int_cache_idx, 0
    .rept PYM_INT_CACHE_COUNT
        .quad 1                                     /* ob_refcnt = 1         */
        .quad pym_int_type                          /* ob_type   = &int type */
        .quad pym_int_cache_idx - 5                 /* value     = idx - 5   */
        .set pym_int_cache_idx, pym_int_cache_idx + 1
    .endr

/* Keep the heap page non-executable. */
    .section .note.GNU-stack,"",@progbits
