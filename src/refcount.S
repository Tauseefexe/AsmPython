/* ============================================================================
 *  AsmPython  --  a from-scratch CPython clone in x86-64 assembly.
 *
 *  FILE    : src/refcount.S
 *  PHASE   : 2  (REFERENCE COUNTING)
 *  PURPOSE : Implement the two lifetime primitives that CPython's entire
 *            memory model rests on, plus the first concrete built-in type.
 *
 *                void asm_incref(PyObject *op);
 *                    acquire one reference: ob_refcnt += 1.
 *
 *                int  asm_decref(PyObject *op);
 *                    release one reference: ob_refcnt -= 1; when it reaches
 *                    0, dispatch to the object type's dealloc slot (which for
 *                    a plain object returns the memory to the free list).
 *                    Returns 0 if the object is still alive, 1 if it was
 *                    deallocated.
 *
 *   A minimal PyTypeObject is introduced so dealloc can be reached:
 *
 *        PyTypeObject {
 *            const char *name;               // +0  human-readable type name
 *            void (*dealloc)(PyObject *);    // +8  how to destroy an instance
 *        }
 *
 *  ABI     : System V AMD64 (Linux).
 *  ASSEMBLER: GNU as (GAS), Intel syntax.  Callee-saved regs we touch
 *             (rbx rbp r12-r15) are preserved via push/pop.
 * ==========================================================================*/

    .intel_syntax noprefix

/* Offsets shared with the rest of the runtime. */
    .equ PY_OFFSET_REFCNT,  0        /* ob_refcnt within a PyObject           */
    .equ PY_OFFSET_TYPE,    8        /* ob_type   within a PyObject           */
    .equ PY_OBJECT_SIZE,    16
    .equ PY_TYPE_OFFSET_NAME,    0   /* type.name   (const char*)             */
    .equ PY_TYPE_OFFSET_DEALLOC, 8   /* type.dealloc (void (*)(PyObject*))    */
    .equ PY_TYPE_OFFSET_BASIC,  16   /* type.basic_size (uint64)              */
    .equ PY_TYPE_SIZE,           24

/* ============================================================================
 * 1.  REGISTER AND MEMORY MAP
 * ----------------------------------------------------------------------------
 *   asm_incref
 *     in : rdi = PyObject*
 *     out: none
 *
 *   asm_decref
 *     in : rdi = PyObject*
 *     out: eax = 0 (object still alive) | 1 (object was deallocated)
 *     temporary: rax/rdx scratch across the dealloc call
 *     rdi is live across the dealloc dispatch -> parked in a push/pop.
 *
 *   Deallocated plain objects land on the runtime free list (free_head, see
 *   pyobject.S) via asm_pyobject_free().
 * ==========================================================================*/

/* ----------------------------------------------------------------------------
 * 2.  INCREF -- acquire a reference
 *      void asm_incref(PyObject *op)
 * ------------------------------------------------------------------------- */
    .section .text

    .globl asm_incref
    .type  asm_incref, @function
asm_incref:
    mov    rax, [rdi + PY_OFFSET_REFCNT]   /* load current refcount           */
    add    rax, 1                          /* +1                              */
    mov    [rdi + PY_OFFSET_REFCNT], rax   /* store it back                   */
    ret
    .size asm_incref, . - asm_incref

/* ----------------------------------------------------------------------------
 * 3.  DECREF -- release a reference (deallocating at zero)
 *      int asm_decref(PyObject *op)
 * ------------------------------------------------------------------------- */
    .globl asm_decref
    .type  asm_decref, @function
asm_decref:
    mov    rax, [rdi + PY_OFFSET_REFCNT]   /* rax = current refcount          */
    test   rax, rax                        /* already 0?                      */
    jz     .decref_done_zero               /* yes -> cannot underflow: return */
                                           /*        "dead" harmlessly        */
    sub    rax, 1                          /* release one reference           */
    jnz    .decref_alive                   /* still > 0 -> just store it back */

    /* ---- refcount reached exactly zero: destroy the object ---- */
    mov    qword ptr [rdi + PY_OFFSET_REFCNT], 0  /* park ob_refcnt at 0       */
    mov    rax, [rdi + PY_OFFSET_TYPE]      /* rax = op->ob_type               */
    mov    rax, [rax + PY_TYPE_OFFSET_DEALLOC]    /* rax = type->dealloc      */
    test   rax, rax                        /* does this type free instances?  */
    jz     .decref_no_dealloc              /* no  -> nothing to dispatch to   */

    push   rdi                             /* keep op across the call         */
    call   rax                             /* dealloc(op)                     */
    pop    rdi

.decref_no_dealloc:
    mov    eax, 1                          /* signal: object is gone          */
    ret

.decref_alive:
    mov    [rdi + PY_OFFSET_REFCNT], rax   /* store the decremented count     */
    xor    eax, eax                        /* signal: object still alive      */
    ret

.decref_done_zero:
    mov    eax, 1                          /* already dead; report as gone    */
    ret
    .size asm_decref, . - asm_decref

/* ============================================================================
 * 4.  THE BUILT-IN "object" TYPE
 * ----------------------------------------------------------------------------
 *   A real, runtime-resident type object. Instances of `object` carry no
 *   extra state, so their dealloc slot simply recycles the slot with
 *   asm_pyobject_free(). The `.quad` words below are normal data relocations
 *   resolved by the dynamic linker / loader.
 * ------------------------------------------------------------------------- */
    .globl asm_object_type
    .section .data
    .balign 16
asm_object_type:
    .quad asm_object_type_name      /* +0  name        -> "object" (rodata)    */
    .quad asm_pyobject_free         /* +8  dealloc     -> recycle the slot     */
    .quad PY_OBJECT_SIZE            /* +16 basic_size  -> sizeof(PyObject)     */

/* Human-readable name for diagnostics (read-only). */
    .section .rodata
asm_object_type_name:
    .asciz "object"

/* Keep the heap page non-executable. */
    .section .note.GNU-stack,"",@progbits
