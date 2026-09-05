/* ============================================================================
 *  AsmPython  --  a from-scratch CPython clone in x86-64 assembly.
 *
 *  FILE    : src/compile.S
 *  PHASE   : 8  (THE COMPILER -- SOURCE TEXT -> VM BYTECODE)
 *  PURPOSE : Close the loop. Phase 7 tokenises source; Phase 6 executes VM
 *            bytecode; THIS phase parses those tokens and emits bytecode, so
 *            a real Python source string is compiled and then runnable by the
 *            very same virtual machine.
 *
 *  MINI-LANGUAGE (a genuine, unambiguous subset of Python syntax):
 *      program   := statement*
 *      statement := NAME '=' expr            (assignment to a module global)
 *                 | 'print' '(' expr ')'     (print expression, like print(x))
 *                 | expr                     (bare expression, discarded)
 *      expr      := term (('+'|'-') term)*   (left-associative + and -)
 *      term      := INT | NAME | '(' expr ')'
 *
 *  OUTPUT  (all produced into this module's static buffers, one program at a
 *           time -- reset at the start of each asm_compile call):
 *      code[]     : VM instruction words (see src/vm.S for the encoding)
 *      consts[]   : PyObject* constant pool (integer literals)
 *      names[]    : interning table mapping global-name slices to indices
 *
 *  The virtual machine reads the finished program from the exported buffers,
 *  so the harness (and eventually the runtime) runs the compiled result with
 *  asm_vm_run(). Compiler state is module-static for simplicity; a full
 *  CPython would use per-frame state, which is a later phase.
 *
 *  ABI/ASSEMBLER : System V AMD64; GNU as Intel syntax.
 * ==========================================================================*/

    .intel_syntax noprefix

/* LexToken offsets (see include/asmpython.h). */
    .equ LEX_OFF_TYPE,   0
    .equ LEX_OFF_START,  8
    .equ LEX_OFF_LENGTH, 16
    .equ LEX_OFF_VALUE,  24

/* Token kinds. */
    .equ TOK_EOF,   0
    .equ TOK_INT,   1
    .equ TOK_NAME,  2
    .equ TOK_OP,    3
    .equ TOK_STR,   4

/* VM opcodes (see src/vm.S / include/asmpython.h). */
    .equ VMOP_LOAD_CONST,   1
    .equ VMOP_LOAD_GLOBAL,  2
    .equ VMOP_STORE_GLOBAL, 3
    .equ VMOP_BINARY_ADD,   4
    .equ VMOP_BINARY_SUB,   5
    .equ VMOP_PRINT,        6
    .equ VMOP_POP,          7
    .equ VMOP_RETURN_VALUE, 8
    .equ VMOP_COMPARE,      9

/* Lexer value codes for comparison operators. Single-char '<' '>' keep their
 * ASCII code (60, 62); the two-char ops are reported as 200 ('==') / 201 ('!='). */
    .equ OPCH_LT,   '<'
    .equ OPCH_GT,   '>'
    .equ OPCH_EQ,   200
    .equ OPCH_NE,   201

/* comparison selector operands (match VMOP_COMPARE) */
    .equ CMP_SEL_EQ, 0
    .equ CMP_SEL_NE, 1
    .equ CMP_SEL_LT, 2
    .equ CMP_SEL_GT, 3

/* Compiler limits. */
    .equ CODE_CAP,    4096
    .equ CONSTS_CAP,   512
    .equ NAMES_CAP,     64
    .equ NAME_MAX,      32

/* Parser error return. */
    .equ COMPILE_ERR,   -1

/* ============================================================================
 *  1.  STATE
 * ----------------------------------------------------------------------------
 *   All compiler state lives here (module-static, .bss). Keeping it in
 *   explicit memory rather than fighting for registers across many helper
 *   calls makes the parser's bookkeeping explicit and easy to verify.
 * ==========================================================================*/
    .section .bss
    .balign 16
g_src:      .zero 8          /* char* source being compiled                 */
g_pos:      .zero 8          /* lexer position (u64)                        */
g_cur:      .zero 32         /* current LexToken (already fetched)          */
g_ncode:    .zero 8          /* number of emitted instructions              */
g_nconst:   .zero 8          /* number of constants in the pool             */
g_nname:    .zero 8          /* number of interned global names             */
g_code:     .zero CODE_CAP*8
g_consts:   .zero CONSTS_CAP*8
g_name_len: .zero NAMES_CAP     /* byte length of each name (u8)            */
g_names:    .zero NAMES_CAP*NAME_MAX

/* ============================================================================
 *  2.  EXPORTED ACCESSORS (so the C harness can build the VmFrame)
 * ==========================================================================*/
    .section .text

    .globl asm_compile_get_code
    .type  asm_compile_get_code, @function
asm_compile_get_code:
    lea    rax, [rip + g_code]
    ret
    .size asm_compile_get_code, . - asm_compile_get_code

    .globl asm_compile_code_len
    .type  asm_compile_code_len, @function
asm_compile_code_len:
    mov    rax, [rip + g_ncode]
    ret
    .size asm_compile_code_len, . - asm_compile_code_len

    .globl asm_compile_get_consts
    .type  asm_compile_get_consts, @function
asm_compile_get_consts:
    lea    rax, [rip + g_consts]
    ret
    .size asm_compile_get_consts, . - asm_compile_get_consts

    .globl asm_compile_consts_len
    .type  asm_compile_consts_len, @function
asm_compile_consts_len:
    mov    rax, [rip + g_nconst]
    ret
    .size asm_compile_consts_len, . - asm_compile_consts_len

    .globl asm_compile_nglobals
    .type  asm_compile_nglobals, @function
asm_compile_nglobals:
    mov    rax, [rip + g_nname]
    ret
    .size asm_compile_nglobals, . - asm_compile_nglobals

/* ----------------------------------------------------------------------------
 *  3.  LOW-LEVEL HELPERS (used by the parser)
 * ------------------------------------------------------------------------- */

/* --- emit(op in edi, operand in esi) : append one instruction word ------- */
emit:
    mov    rax, [rip + g_ncode]
    cmp    rax, CODE_CAP
    jae    .emit_full
    mov    rdx, rax
    mov    rax, rsi
    shl    rax, 16
    or     rax, rdi                   /* word = (operand<<16)|opcode        */
    lea    rcx, [rip + g_code]
    mov    [rcx + rdx*8], rax
    mov    rax, [rip + g_ncode]
    inc    rax
    mov    [rip + g_ncode], rax
    xor    eax, eax
    ret
.emit_full:
    mov rax, COMPILE_ERR
    ret
    .size emit, . - emit

/* --- const_add(value in rdi) : intern an int literal; returns index ------
 *     Creates the int object (CPython cache handles -5..256) and stores it
 *     in the pool. Returns the pool index in rax. ------------------------- */
const_add:
    push   rbx
    call   asm_int_new                /* rax = int object                  */
    test   rax, rax
    jz     .cadd_fail
    mov    rbx, rax                   /* keep the object (asm_int_new ok)  */
    mov    rax, [rip + g_nconst]
    cmp    rax, CONSTS_CAP
    jae    .cadd_fail
    lea    rcx, [rip + g_consts]
    mov    [rcx + rax*8], rbx         /* consts[n] = object                */
    mov    rbx, rax                   /* index                             */
    inc    rax
    mov    [rip + g_nconst], rax
    mov    rax, rbx                   /* return the index                  */
    xor    edx, edx
    pop    rbx
    ret
.cadd_fail:
    mov rax, COMPILE_ERR
    pop    rbx
    ret
    .size const_add, . - const_add

/* --- const_str_add() : intern the current TOK_STR token as a string const.
 *     The token slice includes the surrounding quotes; we build the object
 *     from the inner content src[start+1 .. start+length-2]. Returns index. - */
const_str_add:
    push   rbx
    push   r12
    /* compute inner pointer and length */
    mov    rax, [rip + g_src]
    mov    rcx, [rip + g_cur + LEX_OFF_START]
    lea    rdi, [rax + rcx + 1]       /* inner start = src + start + 1       */
    mov    rsi, [rip + g_cur + LEX_OFF_LENGTH]
    sub    rsi, 2                     /* inner length = length - 2           */
    call   asm_str_new                /* rax = str object                    */
    test   rax, rax
    jz     .csadd_fail
    mov    rbx, rax
    mov    rax, [rip + g_nconst]
    cmp    rax, CONSTS_CAP
    jae    .csadd_fail
    lea    rcx, [rip + g_consts]
    mov    [rcx + rax*8], rbx         /* consts[n] = object                  */
    mov    r12, rax                   /* index                               */
    inc    rax
    mov    [rip + g_nconst], rax
    mov    rax, r12
    pop    r12
    pop    rbx
    ret
.csadd_fail:
    mov    rax, COMPILE_ERR
    pop    r12
    pop    rbx
    ret
    .size const_str_add, . - const_str_add

/* --- cur_slice_ptr() : rax = &src[tok.start] (assumes cur is a NAME) ----- */
cur_slice_ptr:
    mov    rax, [rip + g_src]
    mov    rcx, [rip + g_cur + LEX_OFF_START]
    add    rax, rcx
    ret
    .size cur_slice_ptr, . - cur_slice_ptr

/* --- name_at(i) : rax = &g_names[i] -------------------------------------- */
name_at:
    lea    rax, [rip + g_names]
    imul   rdi, rdi, NAME_MAX
    add    rax, rdi
    ret
    .size name_at, . - name_at

/* --- slice_equals_name(i, slice) : is current token slice == names[i]? ----
 *     i in rdi. Returns 1/0 in rax.                                         */
slice_equals_name:
    push   rbx
    push   r12
    mov    rbx, rdi                   /* i  (saved: survives the call below)  */
    lea    rcx, [rip + g_name_len]
    movzx  ecx, byte ptr [rcx + rbx]  /* stored length of names[i]            */
    mov    rax, [rip + g_cur + LEX_OFF_LENGTH]
    cmp    rcx, rax
    jne    .sen_false                 /* length mismatch -> not equal        */
    test   rcx, rcx
    jz     .sen_true                  /* both zero-length -> equal            */

    mov    rdi, rbx
    call   name_at                    /* rax = &names[i]                      */
    mov    r12, rax                   /* names ptr (SAVED register)           */
    call   cur_slice_ptr              /* rax = slice ptr (clobbers rcx etc)   */
    mov    rsi, rax                   /* slice ptr                            */
    mov    rcx, [rip + g_cur + LEX_OFF_LENGTH]  /* byte count                */

    /* compare [rsi] against [r12] for rcx bytes */
.sen_cmp_loop:
    mov    r8b, [rsi]
    mov    r9b, [r12]
    cmp    r8b, r9b
    jne    .sen_false
    inc    rsi
    inc    r12
    dec    rcx
    jnz    .sen_cmp_loop
    /* fall through -> equal */
    mov    eax, 1
    pop    r12
    pop    rbx
    ret
.sen_true:
    mov    eax, 1
    pop    r12
    pop    rbx
    ret
.sen_false:
    xor    eax, eax
    pop    r12
    pop    rbx
    ret
    .size slice_equals_name, . - slice_equals_name

/* --- name_intern() : intern the current NAME token; returns its index ----- */
name_intern:
    push   rbx
    push   r12
    push   r13
    mov    r13, 0                     /* index i                            */
.name_lookup:
    mov    rax, [rip + g_nname]
    cmp    r13, rax
    jae    .name_new
    mov    rdi, r13
    call   slice_equals_name          /* 1 if matches                       */
    test   rax, rax
    jnz    .name_found
    inc    r13
    jmp    .name_lookup
.name_found:
    mov    rax, r13
    pop    r13
    pop    r12
    pop    rbx
    ret
.name_new:
    mov    rax, [rip + g_nname]
    cmp    rax, NAMES_CAP
    jae    .name_oflow
    mov    rbx, rax                   /* new index                          */
    call   cur_slice_ptr              /* rax = slice                        */
    mov    rsi, rax                   /* source                             */
    mov    rax, [rip + g_cur + LEX_OFF_LENGTH]
    mov    rdx, rax                   /* length                             */
    cmp    rdx, NAME_MAX
    ja     .name_oflow
    mov    r12, rdx                   /* length                             */
    mov    rdi, rbx
    call   name_at                    /* rax = &names[new]                  */
    mov    rdi, rax                   /* dest                               */
    mov    rcx, r12                   /* count                              */
    /* copy rcx bytes from [rsi] to [rdi] */
.name_cp:
    test   rcx, rcx
    jz     .name_cp_done
    mov    r8b, [rsi]
    mov    [rdi], r8b
    inc    rsi
    inc    rdi
    dec    rcx
    jmp    .name_cp
.name_cp_done:
    lea    rcx, [rip + g_name_len]
    mov    byte ptr [rcx + rbx], r12b /* record length                      */
    mov    rax, [rip + g_nname]
    inc    rax
    mov    [rip + g_nname], rax
    mov    rax, rbx                   /* return new index                   */
    pop    r13
    pop    r12
    pop    rbx
    ret
.name_oflow:
    mov rax, COMPILE_ERR
    pop    r13
    pop    r12
    pop    rbx
    ret
    .size name_intern, . - name_intern

/* --- is_print() : does the current NAME token spell "print"? returns 1/0 -- */
is_print:
    mov    rax, [rip + g_cur + LEX_OFF_TYPE]
    cmp    rax, TOK_NAME
    jne    .ip_false
    mov    rax, [rip + g_cur + LEX_OFF_LENGTH]
    cmp    rax, 5
    jne    .ip_false
    call   cur_slice_ptr
    lea    rcx, [rip + pym_kw_print]
    mov    rdx, 5
.ip_cmp:
    test   rdx, rdx
    jz     .ip_true
    mov    r8b, [rax]
    mov    r9b, [rcx]
    cmp    r8b, r9b
    jne    .ip_false
    inc    rax
    inc    rcx
    dec    rdx
    jmp    .ip_cmp
.ip_true:
    mov    eax, 1
    ret
.ip_false:
    xor    eax, eax
    ret
    .size is_print, . - is_print

/* --- kw_match(rdi=text, rsi=len) : is the current NAME token equal to the
 *     given (length, bytes)? Returns 1/0.                                  */
kw_match:
    push   rbx
    push   r12
    mov    rbx, rdi                   /* text (saved)                       */
    mov    r12, rsi                   /* len  (saved)                       */
    mov    rax, [rip + g_cur + LEX_OFF_TYPE]
    cmp    rax, TOK_NAME
    jne    .kw_no
    mov    rax, [rip + g_cur + LEX_OFF_LENGTH]
    cmp    rax, r12
    jne    .kw_no
    call   cur_slice_ptr              /* rax = slice ptr                    */
    mov    rcx, r12                   /* counter                            */
.kw_cmp:
    mov    r8b, [rax]
    mov    r9b, [rbx]
    cmp    r8b, r9b
    jne    .kw_no
    inc    rax
    inc    rbx
    dec    rcx
    jnz    .kw_cmp
    mov    eax, 1
    pop    r12
    pop    rbx
    ret
.kw_no:
    xor    eax, eax
    pop    r12
    pop    rbx
    ret
    .size kw_match, . - kw_match

/* --- singleton_for_current() : if the current NAME is True/False/None,
 *     return that object's address; else return 0.                         */
singleton_for_current:
    push   rbx
    lea    rdi, [rip + pym_kw_True]
    mov    esi, 4
    call   kw_match
    test   rax, rax
    jz     .sg_false
    lea    rax, [rip + pym_True]
    jmp    .sg_out
.sg_false:
    lea    rdi, [rip + pym_kw_False]
    mov    esi, 5
    call   kw_match
    test   rax, rax
    jz     .sg_none
    lea    rax, [rip + pym_False]
    jmp    .sg_out
.sg_none:
    lea    rdi, [rip + pym_kw_None]
    mov    esi, 4
    call   kw_match
    test   rax, rax
    jz     .sg_zero
    lea    rax, [rip + pym_None]
    jmp    .sg_out
.sg_zero:
    xor    eax, eax
.sg_out:
    pop    rbx
    ret
    .size singleton_for_current, . - singleton_for_current

/* --- objconst_add(rdi = object) : store an arbitrary object in the const
 *     pool (pool now owns one reference). Returns its index or -1.         */
objconst_add:
    push   rbx
    mov    rax, [rip + g_nconst]
    cmp    rax, CONSTS_CAP
    jae    .oc_fail
    lea    rcx, [rip + g_consts]
    mov    [rcx + rax*8], rdi         /* consts[n] = obj                    */
    mov    rbx, rax                   /* index                              */
    inc    rax
    mov    [rip + g_nconst], rax
    mov    rax, rbx
    pop    rbx
    ret
.oc_fail:
    mov rax, COMPILE_ERR
    pop    rbx
    ret
    .size objconst_add, . - objconst_add

/* --- expect_op(ch) : current token must be TOK_OP == ch. advance, else err
 *     ch in rdi. Returns 0 ok / -1 err.                                    */
expect_op:
    mov    rax, [rip + g_cur + LEX_OFF_TYPE]
    cmp    rax, TOK_OP
    jne    .eo_fail
    mov    rax, [rip + g_cur + LEX_OFF_VALUE]
    cmp    rax, rdi
    jne    .eo_fail
    call   next_tok                  /* consume it; advance to next token  */
    xor    eax, eax                  /* success, regardless of the next lex  */
    ret
.eo_fail:
    mov rax, COMPILE_ERR
    ret
    .size expect_op, . - expect_op

/* --- next_tok() : load the next token into g_cur. Returns lexer code. ------ */
next_tok:
    mov    rdi, [rip + g_src]
    lea    rsi, [rip + g_pos]
    lea    rdx, [rip + g_cur]
    jmp    asm_lex                   /* tail call                           */
    .size next_tok, . - next_tok

/* ----------------------------------------------------------------------------
 *  4.  PARSER
 * ------------------------------------------------------------------------- */

/* --- parse_term() : INT | NAME | '(' expr ')'. Returns 0/-1. ---------------- */
parse_term:
    push   rbx
    mov    rax, [rip + g_cur + LEX_OFF_TYPE]
    cmp    rax, TOK_INT
    je     .pt_int
    cmp    rax, TOK_NAME
    je     .pt_name
    cmp    rax, TOK_STR
    je     .pt_str
    cmp    rax, TOK_OP
    jne    .pt_err
    mov    rax, [rip + g_cur + LEX_OFF_VALUE]
    cmp    rax, '('
    jne    .pt_err
    call   next_tok
    call   parse_expr
    test   rax, rax
    jnz    .pt_err                   /* propagate error                     */
    mov    rdi, ')'
    call   expect_op
    test   rax, rax
    jnz    .pt_err
    xor    eax, eax
    pop    rbx
    ret
.pt_int:
    mov    rdi, [rip + g_cur + LEX_OFF_VALUE]
    call   const_add                 /* rax = const index                   */
    cmp    rax, COMPILE_ERR
    je     .pt_err
    mov    rsi, rax
    mov    edi, VMOP_LOAD_CONST
    call   emit
    call   next_tok
    xor    eax, eax
    pop    rbx
    ret
.pt_name:
    call   singleton_for_current     /* True/False/None?                    */
    test   rax, rax
    jnz    .pt_name_singleton
    call   name_intern               /* rax = name index                    */
    cmp    rax, COMPILE_ERR
    je     .pt_err
    mov    rsi, rax
    mov    edi, VMOP_LOAD_GLOBAL
    call   emit
    call   next_tok
    xor    eax, eax
    pop    rbx
    ret
.pt_name_singleton:
    mov    rdi, rax
    call   objconst_add              /* store the singleton in the pool     */
    cmp    rax, COMPILE_ERR
    je     .pt_err
    mov    rsi, rax
    mov    edi, VMOP_LOAD_CONST
    call   emit
    call   next_tok
    xor    eax, eax
    pop    rbx
    ret
.pt_str:
    call   const_str_add             /* rax = const index of the string      */
    cmp    rax, COMPILE_ERR
    je     .pt_err
    mov    rsi, rax
    mov    edi, VMOP_LOAD_CONST
    call   emit
    call   next_tok
    xor    eax, eax
    pop    rbx
    ret
.pt_err:
    mov rax, COMPILE_ERR
    pop    rbx
    ret
    .size parse_term, . - parse_term

/* --- parse_arith() : term (('+'|'-') term)*. Returns 0/-1. ------------------ */
parse_arith:
    push   rbx
    push   r12
    call   parse_term
    test   rax, rax
    jnz    .pa_err
.pa_loop:
    /* inspect current token: '+' or '-' continues the expression */
    mov    rax, [rip + g_cur + LEX_OFF_TYPE]
    cmp    rax, TOK_OP
    jne    .pa_done_ok
    mov    r12, [rip + g_cur + LEX_OFF_VALUE]  /* the operator char        */
    cmp    r12, '+'
    je     .pa_op
    cmp    r12, '-'
    jne    .pa_done_ok
.pa_op:
    call   next_tok
    call   parse_term
    test   rax, rax
    jnz    .pa_err
    mov    rbx, r12
    mov    edi, VMOP_BINARY_ADD
    cmp    rbx, '-'
    jne    .pa_add
    mov    edi, VMOP_BINARY_SUB
.pa_add:
    xor    esi, esi
    call   emit
    jmp    .pa_loop
.pa_done_ok:
    xor    eax, eax
    jmp    .pa_out
.pa_err:
    mov rax, COMPILE_ERR
.pa_out:
    pop    r12
    pop    rbx
    ret
    .size parse_arith, . - parse_arith

/* --- parse_expr() : parse_arith [ comp parse_arith ]. Returns 0/-1. ---------
 *   The comparison layer sits just above arithmetic so `print(2 < 3)` and
 *   `a == b` compile. One comparison per expression is supported for now.  */
parse_expr:
    push   rbx
    push   r12
    call   parse_arith
    test   rax, rax
    jnz    .px_err

    /* is the next token a comparison operator? */
    mov    rax, [rip + g_cur + LEX_OFF_TYPE]
    cmp    rax, TOK_OP
    jne    .px_done_ok
    mov    r12, [rip + g_cur + LEX_OFF_VALUE]

    /* map the operator to its comparison selector (0..3), else not a comp */
    mov    rbx, CMP_SEL_EQ
    cmp    r12, OPCH_EQ              /* == */
    je     .px_op
    mov    rbx, CMP_SEL_NE
    cmp    r12, OPCH_NE              /* != */
    je     .px_op
    mov    rbx, CMP_SEL_LT
    cmp    r12, OPCH_LT              /* <  */
    je     .px_op
    mov    rbx, CMP_SEL_GT
    cmp    r12, OPCH_GT              /* >  */
    jne    .px_done_ok               /* not a comparison -> done            */

.px_op:
    call   next_tok                  /* consume the operator                */
    call   parse_arith               /* parse the right operand             */
    test   rax, rax
    jnz    .px_err
    mov    esi, ebx                  /* selector                            */
    mov    edi, VMOP_COMPARE
    call   emit
    xor    eax, eax
    jmp    .px_out
.px_done_ok:
    xor    eax, eax
    jmp    .px_out
.px_err:
    mov rax, COMPILE_ERR
.px_out:
    pop    r12
    pop    rbx
    ret
    .size parse_expr, . - parse_expr

/* --- parse_statement() : one statement. Returns: 0 done / 1 eof / -1 err. --- */
parse_statement:
    push   rbx
    push   r12
    mov    rax, [rip + g_cur + LEX_OFF_TYPE]
    cmp    rax, TOK_EOF
    je     .ps_eof
    cmp    rax, TOK_NAME
    je     .ps_name
    /* expression statement (INT or '(') */
    call   parse_expr
    test   rax, rax
    jnz    .ps_err
    mov    edi, VMOP_POP
    xor    esi, esi
    call   emit
    xor    eax, eax
    jmp    .ps_done

.ps_name:
    call   is_print
    test   rax, rax
    jnz    .ps_print

    /* assignment: NAME '=' expr -> STORE_GLOBAL */
    call   name_intern               /* rax = lhs name index                */
    cmp    rax, COMPILE_ERR
    je     .ps_err
    mov    r12, rax                  /* remember lhs index                  */
    call   next_tok                  /* consume NAME                        */
    mov    rdi, '='
    call   expect_op                 /* consume '='                          */
    test   rax, rax
    jnz    .ps_err
    call   parse_expr
    test   rax, rax
    jnz    .ps_err
    mov    rsi, r12
    mov    edi, VMOP_STORE_GLOBAL
    call   emit
    xor    eax, eax
    jmp    .ps_done

.ps_print:
    /* 'print' '(' expr ')' -> expr, PRINT */
    call   next_tok                  /* consume 'print'                     */
    mov    rdi, '('
    call   expect_op
    test   rax, rax
    jnz    .ps_err
    call   parse_expr
    test   rax, rax
    jnz    .ps_err
    mov    rdi, ')'
    call   expect_op
    test   rax, rax
    jnz    .ps_err
    mov    edi, VMOP_PRINT
    xor    esi, esi
    call   emit
    xor    eax, eax
    jmp    .ps_done

.ps_eof:
    mov    eax, 1
    jmp    .ps_done
.ps_err:
    mov rax, COMPILE_ERR
.ps_done:
    pop    r12
    pop    rbx
    ret
    .size parse_statement, . - parse_statement

/* ----------------------------------------------------------------------------
 *  5.  PUBLIC ENTRY POINT
 *      int asm_compile(const char *src)
 * ----------------------------------------------------------------------------
 *   Reset state, parse every statement, then finish the program so it can be
 *   executed: push constant 0 and RETURN_VALUE (the VM's only stop signal).
 * ------------------------------------------------------------------------- */
    .globl asm_compile
    .type  asm_compile, @function
asm_compile:
    push   rbx
    mov    [rip + g_src], rdi        /* remember source                    */
    mov    qword ptr [rip + g_pos], 0
    mov    qword ptr [rip + g_ncode], 0
    mov    qword ptr [rip + g_nconst], 0
    mov    qword ptr [rip + g_nname], 0
    /* reserve constant 0 = int 0 (used by the epilogue RETURN)            */
    mov    edi, 0
    call   const_add
    cmp    rax, COMPILE_ERR
    je     .c_fail
    call   next_tok                  /* load the first token               */
.c_stmt_loop:
    call   parse_statement
    cmp    rax, COMPILE_ERR
    je     .c_fail
    test   rax, rax
    jz     .c_stmt_loop              /* 0 => parsed a statement; continue  */
    /* rax == 1 => end-of-input reached                                   */
.c_epilogue:
    /* push const 0 and RETURN_VALUE so asm_vm_run terminates cleanly     */
    xor    esi, esi
    mov    edi, VMOP_LOAD_CONST
    call   emit
    mov    edi, VMOP_RETURN_VALUE
    xor    esi, esi
    call   emit
    xor    eax, eax                  /* success                            */
    pop    rbx
    ret
.c_fail:
    mov rax, COMPILE_ERR
    pop    rbx
    ret
    .size asm_compile, . - asm_compile

/* ============================================================================
 *  6.  READ-ONLY DATA
 * ==========================================================================*/
    .section .rodata
pym_kw_print:
    .ascii "print"
pym_kw_True:
    .ascii "True"
pym_kw_False:
    .ascii "False"
pym_kw_None:
    .ascii "None"

/* Keep the heap page non-executable. */
    .section .note.GNU-stack,"",@progbits
