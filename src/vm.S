/* ============================================================================
 *  AsmPython  --  a from-scratch CPython clone in x86-64 assembly.
 *
 *  FILE    : src/vm.S
 *  PHASE   : 6  (THE BYTECODE VIRTUAL MACHINE -- EVALUATION CORE)
 *  PURPOSE : Implement the heart of the interpreter: a dispatch loop that
 *            walks an array of instructions and mutates a stack machine, using
 *            the real PyObject types built in phases 1-5. This is the layer
 *            that eventually turns Python source (via lexer/parser/compiler)
 *            into running behaviour; for now tests hand-build instruction
 *            streams.
 *
 *  INSTRUCTION FORMAT
 *      Each instruction is one 64-bit word:
 *          bits  0-15   opcode
 *          bits 16-63   operand (index into a pool, or unused)
 *
 *  EXECUTION MODEL  (mirrors CPython's bytecode)
 *      * a value operand stack of PyObject* references;
 *      * a constant pool (PyObject**);
 *      * a module-global cell array (PyObject**);
 *      * per-vm_run mutable state held in a caller-owned VmFrame struct.
 *      The eval stack owns a reference to every object it holds; LOAD pushes a
 *      fresh reference, binary ops consume the operands' references, PRINT
 *      consumes one, RETURN_VALUE hands the final object to frame->result.
 *
 *  ABI/ASSEMBLER : System V AMD64; GNU as Intel syntax.
 * ==========================================================================*/

    .intel_syntax noprefix

/* VmFrame offsets -- MUST match struct VmFrame in include/asmpython.h. */
    .equ VM_OFF_CODE,     0
    .equ VM_OFF_NCODE,    8
    .equ VM_OFF_CONSTS,  16
    .equ VM_OFF_NCONSTS, 24
    .equ VM_OFF_GLOBALS, 32
    .equ VM_OFF_NGLOBALS,40
    .equ VM_OFF_VSTACK,  48
    .equ VM_OFF_CAP,     56
    .equ VM_OFF_RESULT,  64
    .equ VM_OFF_PC,      72

/* Opcodes -- MUST match enum in include/asmpython.h. */
    .equ VMOP_LOAD_CONST,  1
    .equ VMOP_LOAD_GLOBAL, 2
    .equ VMOP_STORE_GLOBAL,3
    .equ VMOP_BINARY_ADD,  4
    .equ VMOP_BINARY_SUB,  5
    .equ VMOP_PRINT,       6
    .equ VMOP_POP,         7
    .equ VMOP_RETURN_VALUE,8
    .equ VMOP_COMPARE,     9

/* comparison selector operands for VMOP_COMPARE */
    .equ CMP_EQ,  0
    .equ CMP_NE,  1
    .equ CMP_LT,  2
    .equ CMP_GT,  3

    .equ PY_OFFSET_REFCNT,  0
    .equ PY_OFFSET_TYPE,    8
    .equ PYM_INT_OFFSET_VALUE, 16
    .equ PY_TYPE_OFFSET_NAME,  0

    .equ SYS_WRITE,   1
    .equ STD_OUT,     1

/* ============================================================================
 *  1.  REGISTER MAP for asm_vm_run
 * ----------------------------------------------------------------------------
 *   rbp = VmFrame*   (all object pools/frame state dereferenced through it)
 *   r12 = value-stack top pointer (points past the last pushed object)
 *   r13 = program counter (index into code[])
 *   r15 = decoded operand (survives calls; set fresh every dispatch)
 *   r14 = general scratch that must survive calls (operands/held refs)
 *   rbx = scratch (code pointer / pool bases), free after each decode
 *   All of rbp,r12,r13,r14,r15,rbx are callee-saved, so the leaf helpers
 *   (asm_int_new / asm_decref / asm_print_*) preserve them across our calls.
 * ==========================================================================*/

    .section .text

    .globl asm_vm_run
    .type  asm_vm_run, @function
asm_vm_run:
    push   rbp
    push   r12
    push   r13
    push   r14
    push   r15
    push   rbx
    mov    rbp, rdi                 /* rbp = frame                              */
    mov    r12, [rbp + VM_OFF_VSTACK]   /* r12 = value-stack top               */
    xor    r13d, r13d               /* pc = 0                                   */

/* ---------------- main dispatch loop ---------------- */
.dispatch:
    mov    rbx, [rbp + VM_OFF_CODE]     /* code base                          */
    mov    rax, [rbx + r13*8]           /* fetch instruction word             */
    inc    r13                          /* pc += 1                            */
    mov    r15, rax                     /* r15 = word                          */
    shr    r15, 16                      /* r15 = operand                       */
    movzx  ecx, ax                      /* rcx = opcode (low 16 bits)          */
    lea    r11, [rip + .jump_table]
    jmp    qword ptr [r11 + rcx*8]

/* LOAD_CONST operand -> push consts[operand] (new reference) */
.L_load_const:
    mov    rdi, [rbp + VM_OFF_CONSTS]
    mov    rdi, [rdi + r15*8]           /* obj = consts[operand]              */
    call   asm_incref                   /* new reference (rdi preserved)      */
    mov    [r12], rdi
    add    r12, 8
    jmp    .dispatch

/* LOAD_GLOBAL operand -> push globals[operand] (new reference) */
.L_load_global:
    mov    rdi, [rbp + VM_OFF_GLOBALS]
    mov    rdi, [rdi + r15*8]
    call   asm_incref
    mov    [r12], rdi
    add    r12, 8
    jmp    .dispatch

/* STORE_GLOBAL operand -> globals[operand] = pop() (ownership transfer) */
.L_store_global:
    sub    r12, 8
    mov    rdi, [r12]                   /* obj being stored                  */
    mov    rbx, [rbp + VM_OFF_GLOBALS]
    mov    rax, [rbx + r15*8]           /* previous occupant                 */
    test   rax, rax
    jz     .sg_no_old
    push   rdi
    mov    rdi, rax                     /* release the old reference         */
    call   asm_decref
    pop    rdi
.sg_no_old:
    mov    [rbx + r15*8], rdi           /* global now owns the transferred ref*/
    jmp    .dispatch

/* BINARY_ADD : pop b, pop a -> push a + b  (both operand refs released) */
.L_binary_add:
    mov    r14, [r12 - 16]              /* a (left)                          */
    mov    rsi, [r12 - 8]               /* b (right)                         */
    sub    r12, 16
    mov    rdi, [r14 + PYM_INT_OFFSET_VALUE]
    add    rdi, [rsi + PYM_INT_OFFSET_VALUE]   /* rdi = a.value + b.value    */
    call   asm_int_new                  /* rax = result object              */
    mov    rbx, rax                     /* hold result (asm_int_new saved rbx)*/
    mov    rdi, rsi                     /* release b                         */
    call   asm_decref
    mov    rdi, r14                     /* release a                         */
    call   asm_decref
    mov    [r12], rbx
    add    r12, 8
    jmp    .dispatch

/* BINARY_SUB : pop b, pop a -> push a - b */
.L_binary_sub:
    mov    r14, [r12 - 16]              /* a                                 */
    mov    rsi, [r12 - 8]               /* b                                 */
    sub    r12, 16
    mov    rdi, [r14 + PYM_INT_OFFSET_VALUE]
    sub    rdi, [rsi + PYM_INT_OFFSET_VALUE]   /* rdi = a.value - b.value    */
    call   asm_int_new
    mov    rbx, rax
    mov    rdi, rsi
    call   asm_decref
    mov    rdi, r14
    call   asm_decref
    mov    [r12], rbx
    add    r12, 8
    jmp    .dispatch

/* PRINT : pop object, print it (with newline), release the reference */
.L_print:
    sub    r12, 8
    mov    r14, [r12]                   /* obj to print                      */
    mov    rdi, r14
    call   asm_print_object
    mov    rdi, r14
    call   asm_decref
    jmp    .dispatch

/* COMPARE operand: pop b, pop a -> push bool(a op b). The selector operand
 * (0..3) indexes a table of the int-comparison routines. */
.L_compare:
    mov    r14, [r12 - 16]              /* a                                 */
    mov    rsi, [r12 - 8]               /* b                                 */
    sub    r12, 16
    lea    rbx, [rip + .cmpfuncs]
    mov    rdi, r14
    call   qword ptr [rbx + r15*8]      /* asm_int_*(a,b) -> bool singleton   */
    mov    rbx, rax                     /* hold the result object             */
    mov    rdi, rsi
    call   asm_decref                   /* release b                          */
    mov    rdi, r14
    call   asm_decref                   /* release a                          */
    mov    [r12], rbx                   /* push result (immortal, no incref)  */
    add    r12, 8
    jmp    .dispatch

/* POP : drop the top of the stack (release reference) */
.L_pop:
    sub    r12, 8
    mov    rdi, [r12]
    call   asm_decref
    jmp    .dispatch

/* RETURN_VALUE : result = pop(); stop */
.L_return_value:
    sub    r12, 8
    mov    rax, [r12]
    mov    [rbp + VM_OFF_RESULT], rax   /* hand result to the caller        */
    mov    [rbp + VM_OFF_PC], r13       /* record stopping pc (diagnostics)  */
    pop    rbx
    pop    r15
    pop    r14
    pop    r13
    pop    r12
    pop    rbp
    xor    eax, eax                     /* normal termination                */
    ret

/* ---------------- computed dispatch table ---------------- */
    .align 8
.jump_table:
    .quad .dispatch          /* 0 : unused                                  */
    .quad .L_load_const      /* 1 : LOAD_CONST                              */
    .quad .L_load_global     /* 2 : LOAD_GLOBAL                             */
    .quad .L_store_global    /* 3 : STORE_GLOBAL                            */
    .quad .L_binary_add      /* 4 : BINARY_ADD                              */
    .quad .L_binary_sub      /* 5 : BINARY_SUB                              */
    .quad .L_print           /* 6 : PRINT                                   */
    .quad .L_pop             /* 7 : POP                                     */
    .quad .L_return_value    /* 8 : RETURN_VALUE                            */
    .quad .L_compare         /* 9 : COMPARE (operand = selector)            */
    .size asm_vm_run, . - asm_vm_run

/* ----------------------------------------------------------------------------
 *  comparison routine table (indexed by VMOP_COMPARE operand)
 * ------------------------------------------------------------------------- */
    .align 8
.cmpfuncs:
    .quad asm_int_eq          /* 0 : == */
    .quad asm_int_ne          /* 1 : != */
    .quad asm_int_lt          /* 2 : <  */
    .quad asm_int_gt          /* 3 : >  */

/* ============================================================================
 *  PRINTING HELPERS (write to stdout via the write syscall)
 * ==========================================================================*/

/* --- asm_write(fd=edi, buf=rsi, len=rdx) --- */
    .globl asm_write
    .type  asm_write, @function
asm_write:
    mov    eax, SYS_WRITE
    syscall
    ret
    .size asm_write, . - asm_write

/* --- asm_print_cstr(rdi = NUL-terminated string) : write it to stdout --- */
    .globl asm_print_cstr
    .type  asm_print_cstr, @function
asm_print_cstr:
    push   rbx
    push   r12
    mov    rbx, rdi                   /* keep the string pointer              */
    xor    r12d, r12d                 /* length = 0                           */
.strlen_loop:
    mov    al, [rbx + r12]            /* byte at rbx + length                 */
    test   al, al
    jz     .strlen_done
    inc    r12
    jmp    .strlen_loop
.strlen_done:
    mov    edi, STD_OUT
    mov    rsi, rbx
    mov    rdx, r12
    call   asm_write
    pop    r12
    pop    rbx
    ret
    .size asm_print_cstr, . - asm_print_cstr

/* --- asm_write_char(rdi = single byte value) --- */
    .globl asm_write_char
    .type  asm_write_char, @function
asm_write_char:
    push   rbx                       /* entry rsp%16==8 -> push -> ==0       */
    sub    rsp, 16                   /* reserve room ABOVE the return-address
                                        area so the inner call cannot clobber */
    mov    rbx, rdi
    mov    byte ptr [rsp], bl        /* spill the char into reserved space    */
    mov    edi, STD_OUT
    mov    rsi, rsp
    mov    edx, 1
    call   asm_write
    add    rsp, 16
    pop    rbx
    ret
    .size asm_write_char, . - asm_write_char

/* --- asm_print_int(rdi = int64 value) : decimal digits, no newline --- */
    .globl asm_print_int
    .type  asm_print_int, @function
asm_print_int:
    push   r12
    push   rbp
    sub    rsp, 64                    /* scratch buffer for the digits       */
    mov    rax, rdi                   /* value (as signed)                   */
    xor    ebp, ebp                   /* sign flag: 0 = non-negative         */
    test   rax, rax
    jns    .pint_nonneg
    mov    ebp, 1
    neg    rax                        /* rax = magnitude                     */
.pint_nonneg:
    lea    r12, [rsp + 63]            /* start writing from the buffer end   */
.pint_digit_loop:
    xor    edx, edx
    mov    rcx, 10
    div    rcx                        /* rax = value/10, rdx = value%10      */
    add    dl, '0'
    mov    [r12], dl
    dec    r12
    test   rax, rax
    jnz    .pint_digit_loop
    test   ebp, ebp
    jz     .pint_no_sign
    mov    byte ptr [r12], '-'
    dec    r12
.pint_no_sign:
    lea    rsi, [r12 + 1]             /* first digit                         */
    mov    rdx, r12
    sub    rdx, rsp                   /* offset of char before first digit   */
    neg    rdx
    add    rdx, 63                    /* rdx = number of characters          */
    mov    edi, STD_OUT
    call   asm_write
    add    rsp, 64
    pop    rbp
    pop    r12
    ret
    .size asm_print_int, . - asm_print_int

/* --- asm_print_object(rdi = PyObject*) : CPython-like print(obj) ---------
 *     ints -> decimal; anything else -> its type name. Newline appended.   */
    .globl asm_print_object
    .type  asm_print_object, @function
asm_print_object:
    push   rbx
    mov    rbx, rdi                   /* obj                                 */
    lea    rax, [rip + pym_int_type]
    cmp    qword ptr [rbx + PY_OFFSET_TYPE], rax
    jne    .pobj_not_int
    mov    rdi, [rbx + PYM_INT_OFFSET_VALUE]
    call   asm_print_int
    jmp    .pobj_done
.pobj_not_int:
    lea    rax, [rip + pym_str_type]
    cmp    qword ptr [rbx + PY_OFFSET_TYPE], rax
    jne    .pobj_check_singleton
    mov    rdi, rbx                   /* string object                       */
    call   asm_print_string_object    /* writes payload, no newline          */
    jmp    .pobj_done
.pobj_check_singleton:
    lea    rax, [rip + pym_None]
    cmp    rbx, rax
    je     .pobj_print_none
    lea    rax, [rip + pym_True]
    cmp    rbx, rax
    je     .pobj_print_true
    lea    rax, [rip + pym_False]
    cmp    rbx, rax
    je     .pobj_print_false
    /* fall back to the object's type name */
    mov    rax, [rbx + PY_OFFSET_TYPE]
    mov    rdi, [rax + PY_TYPE_OFFSET_NAME]
    call   asm_print_cstr
    jmp    .pobj_done
.pobj_print_none:
    lea    rdi, [rip + .lit_None]
    call   asm_print_cstr
    jmp    .pobj_done
.pobj_print_true:
    lea    rdi, [rip + .lit_True]
    call   asm_print_cstr
    jmp    .pobj_done
.pobj_print_false:
    lea    rdi, [rip + .lit_False]
    call   asm_print_cstr
.pobj_done:
    mov    edi, 0x0A                  /* '\n'                                 */
    call   asm_write_char
    pop    rbx
    ret
    .size asm_print_object, . - asm_print_object

    .section .rodata
.lit_None:  .asciz "None"
.lit_True:  .asciz "True"
.lit_False: .asciz "False"
    .section .text

/* Keep the heap page non-executable. */
    .section .note.GNU-stack,"",@progbits
