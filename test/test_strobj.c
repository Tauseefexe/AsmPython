/*
 * AsmPython -- Phase 9 validation harness: the str type + string literals.
 *
 *   1. asm_str_new builds a correct object (type, length, bytes, NUL);
 *   2. lexer recognises "..." and '...' string tokens;
 *   3. compiler + VM print string literals: print("hi") emits "hi\n";
 *   4. strings co-exist with ints and arithmetic in the same program.
 *
 * Exits 0 on success, prints failures and exits non-zero otherwise.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>

#include "../include/asmpython.h"

static int failures = 0;

#define CHECK(cond, msg)                                                \
    do {                                                                \
        if (!(cond)) {                                                  \
            fprintf(stderr, "FAIL [%s] at %s:%d\n", msg, __FILE__, __LINE__); \
            failures++;                                                 \
        }                                                               \
    } while (0)

/* compile + run source in this process with stdout captured */
static void run_src(const char *src, char *out, size_t outsz)
{
    if (asm_compile(src) != 0) { out[0] = 0; return; }
    uint64_t ncode  = asm_compile_code_len();
    uint64_t *code  = asm_compile_get_code();
    PyObject **consts = asm_compile_get_consts();
    uint64_t nconsts = asm_compile_consts_len();
    uint64_t nglob  = asm_compile_nglobals();
    PyObject g[128]; memset(g, 0, sizeof g);
    PyObject st[128]; memset(st, 0, sizeof st);
    VmFrame fr; memset(&fr, 0, sizeof fr);
    fr.code = code; fr.ncode = ncode; fr.consts = consts; fr.nconsts = nconsts;
    fr.globals = g; fr.nglobals = nglob; fr.vstack = st; fr.vstack_cap = 128;

    fflush(stdout);
    int saved = dup(STDOUT_FILENO);
    int pfd[2]; pipe(pfd);
    dup2(pfd[1], STDOUT_FILENO); close(pfd[1]);
    asm_vm_run(&fr);
    fflush(stdout);
    dup2(saved, STDOUT_FILENO); close(saved);
    ssize_t n = read(pfd[0], out, outsz - 1); close(pfd[0]);
    if (n < 0) n = 0;
    out[n] = 0;
}

int main(void)
{
    /* --- 1: asm_str_new builds correct objects ------------------------- */
    PyObject *s = asm_str_new("hello", 5);
    CHECK(s != NULL, "str allocated");
    CHECK(s->ob_type == (void *)&pym_str_type, "str ob_type == str");
    if (s) {
        unsigned char *p = (unsigned char *)s + PYM_STR_OFFSET_DATA;
        CHECK(*(uint64_t *)((char *)s + PYM_STR_OFFSET_LENGTH) == 5,
              "str length == 5");
        CHECK(memcmp(p, "hello", 5) == 0, "str bytes == 'hello'");
        CHECK(p[5] == 0, "str has NUL terminator");
    }
    PyObject *empty = asm_str_new("", 0);
    CHECK(empty != NULL && *(uint64_t *)((char *)empty
          + PYM_STR_OFFSET_LENGTH) == 0, "empty string length == 0");

    /* --- 2: lexer recognises quoted literals --------------------------- */
    {
        uint64_t pos = 0; LexToken t;
        const char *src = "print(\"hi\")";
        asm_lex(src, &pos, &t);            /* print */
        CHECK(t.type == TOK_NAME, "token: name print");
        asm_lex(src, &pos, &t);            /* ( */
        asm_lex(src, &pos, &t);            /* "hi"  */
        CHECK(t.type == TOK_STR, "token: string literal");
        CHECK(t.start == 6 && t.length == 4,
              "string token spans the 4 quoted bytes \"hi\"");
        asm_lex(src, &pos, &t);            /* ) */
        asm_lex(src, &pos, &t);            /* EOF */
        CHECK(t.type == TOK_EOF, "string literal lexing reaches EOF");
    }

    /* --- 3 & 4: compile+run prints strings (and mixed programs) -------- */
    char buf[256];
    run_src("print(\"hello\")\n", buf, sizeof buf);
    CHECK(strcmp(buf, "hello\n") == 0, "print(\"hello\") -> 'hello\\n'");

    run_src("print('world')\n", buf, sizeof buf);
    CHECK(strcmp(buf, "world\n") == 0, "single-quoted 'world' prints");

    run_src("print(\"value=\")\nprint(2 + 3)\n", buf, sizeof buf);
    CHECK(strcmp(buf, "value=\n5\n") == 0,
          "mixed string + int print works");

    printf("str object bytes ok; string print output validated\n");

    if (failures == 0) {
        printf("\nPHASE 9 str type + literals: ALL CHECKS PASSED\n");
        return EXIT_SUCCESS;
    }
    fprintf(stderr, "\nPHASE 9 str type + literals: %d check(s) FAILED\n",
            failures);
    return EXIT_FAILURE;
}
