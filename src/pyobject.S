/* ============================================================================
 *  AsmPython  --  a from-scratch CPython clone in x86-64 assembly.
 *
 *  FILE    : src/pyobject.S
 *  PHASES  : 1-3  (PyObject core + object lifecycle + size-class allocator)
 *  PURPOSE : Structural foundation of the runtime. Everything Python touches is
 *            a PyObject, so this file defines the object memory model and the
 *            allocation/deallocation machinery shared by every type:
 *
 *                void *asm_raw_alloc(unsigned long size);
 *                    raw arena memory (mmap-backed), 16-byte aligned. Used for
 *                    large objects and by the size-class layer below.
 *
 *                PyObject *asm_pyobject_new(void *type_ptr);
 *                    allocate an object whose footprint is type->basic_size,
 *                    set ob_refcnt = 1, install ob_type, return it. Fast path
 *                    recycles a matching freed slot if one is available.
 *
 *                void asm_pyobject_free(PyObject *op);
 *                    return `op` to the per-size free list so future
 *                    asm_pyobject_new() calls can reuse its slot. The size
 *                    class is recovered from op->ob_type->basic_size.
 *
 *  SIZE-CLASS MODEL  (the heart of this phase)
 *    A type declares its instance footprint in `basic_size`. Object sizes are
 *    normalised to 16-byte multiples, and any object up to PYMEM_SMALL_MAX
 *    bytes is kept on a free list dedicated to that normalised size. Freed
 *    slots are recycled in LIFO order; the bump arena is only consulted when
 *    no matching slot is free. Large objects (basic_size > SMALL_MAX) are
 *    carved directly from the arena and, in this phase, live for the rest of
 *    the process (their headers are zeroed on free so stale pointers cannot be
 *    mistaken for live objects).
 *
 *  ABI      : System V AMD64 (Linux). Callee-saved regs we touch are saved.
 *  ASSEMBLER: GNU as (GAS), Intel syntax.
 * ==========================================================================*/

    .intel_syntax noprefix          /* operands written as: dst, src (Intel)  */

/* ----------------------------------------------------------------------------
 * 1.  OBJECT / TYPE LAYOUT
 * ----------------------------------------------------------------------------
 *   PyObject (every object's head), 16 bytes:
 *       +0  ob_refcnt   (int64)   reference count, starts at 1
 *       +8  ob_type     (ptr)     -> the object's PyTypeObject
 *
 *   PyTypeObject (minimal, as used by the runtime), 24 bytes:
 *       +0  name        (const char *)   diagnostics
 *       +8  dealloc     (func ptr)       how to destroy an instance
 *       +16 basic_size  (uint64)         bytes an instance of this type needs
 *
 *   All offsets are shared with refcount.S and the C test mirror.
 * ------------------------------------------------------------------------- */
    .equ PY_OFFSET_REFCNT,       0
    .equ PY_OFFSET_TYPE,         8
    .equ PY_OBJECT_SIZE,        16
    .equ PY_TYPE_OFFSET_NAME,    0
    .equ PY_TYPE_OFFSET_DEALLOC, 8
    .equ PY_TYPE_OFFSET_BASIC,  16
    .equ PY_TYPE_SIZE,          24

    .equ PY_BASE_ALIGN,         16        /* all objects are 16-byte aligned   */
    .equ PYMEM_MIN_CHUNK,    65536        /* arena chunk lower bound (64 KiB)  */
    .equ PYMEM_PAGE_SIZE,     4096        /* Linux x86-64 page size            */
    .equ PYMEM_SMALL_MAX,      512        /* biggest object kept on a free list*/
    .equ PYMEM_SMALL_CLASSES,   32        /* 16..512 in steps of 16            */

/* Linux syscall + mmap flag constants (see <sys/mman.h>). */
    .equ SYS_MMAP,               9
    .equ SYS_BRK,               12        /* reserved for a later phase        */
    .equ PROT_READ,             0x01
    .equ PROT_WRITE,            0x02
    .equ MAP_PRIVATE,           0x02
    .equ MAP_ANONYMOUS,         0x20
    .equ MAP_FAILED,            -1

/* ============================================================================
 * 2.  REGISTER AND MEMORY MAP
 * ----------------------------------------------------------------------------
 *   asm_raw_alloc : in rdi=bytes; out rax=aligned ptr or 0.
 *       r12 = size rounded up to *16 (saved, survives the syscall)
 *       rcx = bump pointer, rdx = block end, rsi = mmap length
 *
 *   asm_pyobject_new : in rdi=type; out rax=object ptr or 0.
 *       rbx = type (saved), r12 = normalised size (saved)
 *       rcx = bucket index, rdx = base of free_lists[], rax = slot head
 *
 *   asm_pyobject_free : in rdi=object; no return.
 *       rax/rcx/rdx scratch only (no callee-saved regs touched).
 *
 *   State in .bss:
 *       pymem_ahead / pymem_atop   bump arena window
 *       free_lists[32]             one free-list head per 16-byte size class
 * ==========================================================================*/

/* ----------------------------------------------------------------------------
 * 3a.  PRIVATE RAW ARENA ALLOCATOR
 *      void *asm_raw_alloc(unsigned long size)
 * ----------------------------------------------------------------------------
 *   Fast path: take `size` bytes straight off the current chunk (no syscall).
 *   Slow path: mmap a fresh anonymous chunk (>= 64 KiB, page-aligned) and
 *   carve the request out of its front.
 * ------------------------------------------------------------------------- */
    .section .text

    .globl asm_raw_alloc
    .type  asm_raw_alloc, @function
asm_raw_alloc:
    push   r12
    lea    r12, [rdi + 15]           /* r12 = size rounded ...                */
    and    r12, -16                  /*   ... UP to a multiple of 16          */

    mov    rcx, [rip + pymem_ahead]
    test   rcx, rcx
    jz     .raw_grow                 /* arena not mapped yet                  */

    lea    rdx, [rcx + r12]
    cmp    rdx, [rip + pymem_atop]
    ja     .raw_grow

    /* ---- FAST PATH: fits in the current chunk, no syscall ---- */
    mov    [rip + pymem_ahead], rdx
    mov    rax, rcx
    pop    r12
    ret

    /* ---- SLOW PATH: map a fresh chunk that covers r12 bytes ---- */
.raw_grow:
    mov    rsi, r12
    mov    rax, PYMEM_MIN_CHUNK
    cmp    rsi, rax
    cmovb  rsi, rax                  /* rsi = max(request, 64 KiB)           */
    add    rsi, PYMEM_PAGE_SIZE - 1
    and    rsi, -PYMEM_PAGE_SIZE     /* rsi = mapped length (page multiple)  */

    xor    edi, edi                  /* sys_mmap addr = NULL                 */
    mov    eax, SYS_MMAP             /* syscall nr for mmap                  */
    mov    edx, PROT_READ | PROT_WRITE
    mov    r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov    r8,  -1                   /* fd = -1 (anonymous)                  */
    xor    r9d, r9d                  /* offset = 0                           */
    syscall

    cmp    rax, MAP_FAILED
    je     .raw_oom

    mov    rcx, rax                  /* block start = chunk base             */
    lea    rdx, [rax + rsi]          /* chunk ceiling                        */
    mov    [rip + pymem_atop], rdx
    lea    rdx, [rax + r12]          /* block end = base + request           */
    mov    [rip + pymem_ahead], rdx
    mov    rax, rcx
    pop    r12
    ret

.raw_oom:
    xor    eax, eax
    pop    r12
    ret
    .size asm_raw_alloc, . - asm_raw_alloc

/* ----------------------------------------------------------------------------
 * 3b.  OBJECT FACTORY (size-class aware)
 *      PyObject *asm_pyobject_new(void *type_ptr)
 * ----------------------------------------------------------------------------
 *   basic_size = type->basic_size, rounded up to a multiple of 16 = S.
 *     - small (S <= 512): pop the free list for bucket (S/16 - 1); if empty,
 *       carve a fresh S-byte slot from the arena.
 *     - large (S > 512): carve straight from the arena.
 *   Either way the fresh object is initialised to { ob_refcnt = 1, ob_type }.
 * ------------------------------------------------------------------------- */
    .globl asm_pyobject_new
    .type  asm_pyobject_new, @function
asm_pyobject_new:
    push   rbx
    push   r12                       /* entry rsp%16==8 -> 2 pushes -> 0      */
    mov    rbx, rdi                  /* rbx = type (saved)                    */

    mov    rax, [rdi + PY_TYPE_OFFSET_BASIC]  /* rax = type->basic_size       */
    lea    r12, [rax + 15]           /* r12 = ...                             */
    and    r12, -16                  /* r12 = S (normalised size, >= 16)      */

    /* ---- try to recycle a matching small slot ---- */
    cmp    r12, PYMEM_SMALL_MAX
    ja     .new_arena                /* large object: straight to the arena  */
    mov    rcx, r12
    shr    rcx, 4
    dec    rcx                       /* rcx = bucket index (0..31)            */
    lea    rdx, [rip + free_lists]
    mov    rax, [rdx + rcx*8]        /* rax = head of this size class        */
    test   rax, rax
    jz     .new_arena                /* no free slot -> allocate fresh        */
    mov    rsi, [rax + 0]            /* rax->next                             */
    mov    [rdx + rcx*8], rsi        /* free_lists[bucket] = rax->next (pop)  */
    jmp    .new_init                 /* rax already holds the recycled slot  */

    /* ---- GROW: take a fresh slot from the arena ---- */
.new_arena:
    mov    rdi, r12
    call   asm_raw_alloc
    test   rax, rax
    jz     .new_oom

.new_init:
    mov    qword ptr [rax + PY_OFFSET_REFCNT], 1
    mov    qword ptr [rax + PY_OFFSET_TYPE],   rbx
    pop    r12
    pop    rbx
    ret

.new_oom:
    xor    eax, eax
    pop    r12
    pop    rbx
    ret
    .size asm_pyobject_new, . - asm_pyobject_new

/* ----------------------------------------------------------------------------
 * 3c.  OBJECT DEALLOCATION (size-class reclaim)
 *      void asm_pyobject_free(PyObject *op)
 * ----------------------------------------------------------------------------
 *   Recover the size class from op->ob_type->basic_size, then push `op` onto
 *   that class's free list (LIFO). A freed slot's first qword becomes the
 *   "next" link; its type word is cleared so stale pointers are inert.
 *   Large (arena-backed) objects have their headers zeroed and, by design of
 *   this phase's arena, remain allocated for the process lifetime.
 * ------------------------------------------------------------------------- */
    .globl asm_pyobject_free
    .type  asm_pyobject_free, @function
asm_pyobject_free:
    mov    rax, [rdi + PY_OFFSET_TYPE]        /* rax = op->ob_type           */
    mov    rax, [rax + PY_TYPE_OFFSET_BASIC]  /* rax = type->basic_size      */
    lea    rax, [rax + 15]
    and    rax, -16                           /* rax = S (normalised size)   */
    cmp    rax, PYMEM_SMALL_MAX
    ja     .free_large                         /* large: arena-backed         */

    mov    rcx, rax
    shr    rcx, 4
    dec    rcx                                /* rcx = bucket index          */
    lea    rdx, [rip + free_lists]
    mov    rax, [rdx + rcx*8]                 /* rax = old list head         */
    mov    [rdi + 0], rax                     /* op->next = old head         */
    mov    qword ptr [rdi + PY_OFFSET_TYPE], 0
    mov    [rdx + rcx*8], rdi                 /* head = op (push)            */
    ret

.free_large:
    /* arena-backed object: no reclaim in this phase -- zero the header so a
     * stale reference can never be mistaken for a live object. */
    mov    qword ptr [rdi + PY_OFFSET_REFCNT], 0
    mov    qword ptr [rdi + PY_OFFSET_TYPE],  0
    ret
    .size asm_pyobject_free, . - asm_pyobject_free

/* ============================================================================
 * 4.  ALLOCATOR STATE (zero-initialised, in .bss)
 * ==========================================================================*/
    .section .bss
    .balign 16
    .globl pymem_ahead
pymem_ahead:
    .zero 8                          /* next free byte inside the chunk       */
    .globl pymem_atop
pymem_atop:
    .zero 8                          /* one past the last usable byte         */
    .globl free_lists
free_lists:
    .zero PYMEM_SMALL_CLASSES * 8    /* 32 free-list heads, one per class     */

/* Keep the heap page non-executable (avoids a linker warning + W^X). */
    .section .note.GNU-stack,"",@progbits
