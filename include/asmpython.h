/*
 * AsmPython -- public surface (Phases 1-3).
 *
 * This header is the C-side mirror of the assembly layouts defined in
 * src/pyobject.S and src/refcount.S. It is used ONLY by test harnesses so
 * that the tests can inspect memory the way the runtime will.
 */
#ifndef ASMPYTHON_H
#define ASMPYTHON_H

#include <stdint.h>
#include <stddef.h>

/* ------------------------------------------------------------------ */
/* PyObject layout -- MUST match src/pyobject.S.                       */
/* ------------------------------------------------------------------ */
#define PY_OFFSET_REFCNT 0
#define PY_OFFSET_TYPE   8
#define PY_OBJECT_SIZE   16

/* ------------------------------------------------------------------ */
/* PyTypeObject layout -- MUST match src/pyobject.S / refcount.S.      */
/* ------------------------------------------------------------------ */
#define PY_TYPE_OFFSET_NAME    0
#define PY_TYPE_OFFSET_DEALLOC 8
#define PY_TYPE_OFFSET_BASIC   16
#define PY_TYPE_SIZE           24

/* Size-class allocator parameters -- MUST match src/pyobject.S.       */
#define PYMEM_SMALL_MAX     512
#define PYMEM_SMALL_CLASSES 32        /* 16..512 in steps of 16        */

typedef struct PyObject {
    uint64_t ob_refcnt;              /* +0 */
    void    *ob_type;                /* +8 */
} PyObject;

typedef struct PyTypeObject {
    const char *name;                /* +0  */
    void (*dealloc)(PyObject *);     /* +8  */
    uint64_t    basic_size;          /* +16 : instance footprint in bytes */
} PyTypeObject;

/* ------------------------------------------------------------------ */
/* Routines implemented in assembly (System V AMD64 ABI).              */
/* ------------------------------------------------------------------ */
/* src/pyobject.S */
void     *asm_raw_alloc(uint64_t size);
PyObject *asm_pyobject_new(void *type_ptr);
void      asm_pyobject_free(PyObject *op);

/* src/refcount.S */
void asm_incref(PyObject *op);
int  asm_decref(PyObject *op);        /* 0 = alive, 1 = deallocated */

/* Built-in type objects. */
extern PyTypeObject asm_object_type;
extern PyTypeObject pym_int_type;

/* ------------------------------------------------------------------ */
/* int objects (src/intobj.S) -- Phase 4                               */
/* ------------------------------------------------------------------ */
#define PYM_INT_OFFSET_VALUE  16
#define PYM_INT_SIZE          24
#define PYM_INT_MIN           (-5)
#define PYM_INT_MAX           256
#define PYM_INT_CACHE_COUNT   262
PyObject *asm_int_new(int64_t value);
void      asm_int_dealloc(PyObject *op);
int64_t   asm_int_get_value(PyObject *op);
PyObject *asm_int_add(PyObject *a, PyObject *b);   /* returns a new reference */
PyObject *asm_int_sub(PyObject *a, PyObject *b);
extern unsigned char pym_smallint_cache[];   /* base of the small-int cache */

/* Comparison operators (ints -> True/False) + singletons -- Phase 10. */
PyObject *asm_int_eq(PyObject *a, PyObject *b);
PyObject *asm_int_ne(PyObject *a, PyObject *b);
PyObject *asm_int_lt(PyObject *a, PyObject *b);
PyObject *asm_int_gt(PyObject *a, PyObject *b);
PyObject *asm_bool_new(int truth);
int       asm_bool_value(PyObject *b);
extern PyObject pym_True, pym_False, pym_None;
extern PyTypeObject pym_bool_type, pym_none_type;

/* ------------------------------------------------------------------ */
/* str objects (src/strobj.S) -- Phase 9                               */
/* ------------------------------------------------------------------ */
#define PYM_STR_OFFSET_LENGTH 16
#define PYM_STR_OFFSET_DATA   24
#define PYM_STR_HEADER        24
PyObject *asm_str_new(const char *bytes, uint64_t len);
void      asm_str_dealloc(PyObject *op);
void      asm_print_string_object(PyObject *str_obj);
extern PyTypeObject pym_str_type;

/* ------------------------------------------------------------------ */
/* Output layer (src/io.S) -- Phase 6                                  */
/* ------------------------------------------------------------------ */
uint64_t asm_i64_to_ascii(int64_t value, char *dst);
uint64_t asm_write_stdout(const char *buf, uint64_t len);
void     asm_print_int_object(PyObject *int_obj);
void     asm_print_newline(void);
extern char pym_outbuf[];

/* ------------------------------------------------------------------ */
/* Bytecode virtual machine (src/vm.S) -- Phase 6                       */
/* ------------------------------------------------------------------ */
enum VmOp {
    VMOP_LOAD_CONST   = 1,
    VMOP_LOAD_GLOBAL  = 2,
    VMOP_STORE_GLOBAL = 3,
    VMOP_BINARY_ADD   = 4,
    VMOP_BINARY_SUB   = 5,
    VMOP_PRINT        = 6,
    VMOP_POP          = 7,
    VMOP_RETURN_VALUE = 8,
    VMOP_COMPARE      = 9
};

/* selectors for VMOP_COMPARE */
enum VmCmp { CMP_EQ = 0, CMP_NE = 1, CMP_LT = 2, CMP_GT = 3 };

/* One 64-bit instruction: opcode in bits 0-15, operand in bits 16-63. */
static inline uint64_t vm_insn(unsigned op, uint64_t operand)
{
    return ((uint64_t)operand << 16) | (uint64_t)op;
}

/* Mutable per-run state owned by the caller. Layout MUST match src/vm.S. */
typedef struct VmFrame {
    uint64_t   *code;        /* +0  : instruction words                    */
    uint64_t    ncode;       /* +8  : instruction count                     */
    PyObject  **consts;      /* +16 : constant pool                          */
    uint64_t    nconsts;     /* +24 : pool size                              */
    PyObject  **globals;     /* +32 : module-global cells                    */
    uint64_t    nglobals;    /* +40 : number of global cells                 */
    PyObject  **vstack;      /* +48 : value-operand stack                    */
    uint64_t    vstack_cap;  /* +56 : stack capacity (elements)              */
    PyObject   *result;      /* +64 : value left by RETURN_VALUE             */
    uint64_t    pc;          /* +72 : stopping program counter (diagnostic)  */
} VmFrame;

int asm_vm_run(VmFrame *frame);

/* stdout helpers (src/vm.S). */
void asm_print_cstr(const char *s);       /* up to the terminating NUL      */
void asm_print_int(int64_t value);        /* decimal, no newline            */
void asm_print_object(PyObject *op);      /* repr-ish + newline             */
void asm_write_char(int ch);              /* one byte to stdout             */
int  asm_write(int fd, const void *buf, uint64_t len);

/* ------------------------------------------------------------------ */
/* Lexer (src/lexer.S) -- Phase 7                                      */
/* ------------------------------------------------------------------ */
typedef enum {
    TOK_EOF  = 0,
    TOK_INT  = 1,
    TOK_NAME = 2,
    TOK_OP   = 3,
    TOK_STR  = 4
} LexTokType;

typedef struct LexToken {
    uint64_t type;     /* +0 : TOK_*                                      */
    uint64_t start;    /* +8 : byte offset into the source                */
    uint64_t length;   /* +16: source bytes spanned                       */
    uint64_t value;    /* +24: parsed integer (TOK_INT) / char (TOK_OP)   */
} LexToken;

/* Returns 0 = token produced, 1 = EOF, -1 = error. *pos starts at 0 and is
 * advanced past each token so repeated calls stream the source. */
int asm_lex(const char *src, uint64_t *pos, LexToken *out);

/* ------------------------------------------------------------------ */
/* Compiler (src/compile.S) -- Phase 8                                 */
/* ------------------------------------------------------------------ */
/* Compile Python source into the VM program. Returns 0 on success, -1 on a
 * syntax error. The result is read back through the accessors below. */
int      asm_compile(const char *src);
uint64_t asm_compile_code_len(void);
uint64_t asm_compile_consts_len(void);
uint64_t asm_compile_nglobals(void);
uint64_t *asm_compile_get_code(void);
PyObject **asm_compile_get_consts(void);

/* --- convenience token-category predicates --- */
static inline int tok_is_name(const LexToken *t) { return t->type == TOK_NAME; }
static inline int tok_is_op(const LexToken *t, unsigned char ch)
{ return t->type == TOK_OP && t->value == ch; }

static inline int pym_is_smallint(const PyObject *op)
{
    const unsigned char *b = pym_smallint_cache;
    const unsigned char *e = b + PYM_INT_CACHE_COUNT * PYM_INT_SIZE;
    return (const unsigned char *)op >= b && (const unsigned char *)op < e;
}

/* ------------------------------------------------------------------ */
/* Allocator state exported from .bss (diagnostics/tests).             */
/* ------------------------------------------------------------------ */
extern uintptr_t pymem_ahead;
extern uintptr_t pymem_atop;
extern uintptr_t free_lists[PYMEM_SMALL_CLASSES];

static inline int pymem_aligned(const void *p)
{
    return ((uintptr_t)p % 16u) == 0u;
}

#endif /* ASMPYTHON_H */
