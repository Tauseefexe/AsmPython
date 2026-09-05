/*
 * AsmPython -- Phase 8 validation harness: source -> VM compiler.
 *
 * Compiles real Python source strings, runs the resulting program on the
 * Phase 6 VM (in-process, with stdout temporarily captured), and asserts the
 * observable behaviour:
 *   1. assignment + arithmetic round-trip through a module global;
 *   2. print() writes the exact expected decimal to stdout (captured);
 *   3. nested parenthesised expressions compile and evaluate correctly;
 *   4. bare expression statements are evaluated and discarded (POP);
 *   5. malformed source is reported as a compile error.
 *
 * This closes the loop: source text -> lexer -> compiler -> VM -> output.
 *
 * Exits 0 on success, prints failures and exits non-zero otherwise.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <inttypes.h>
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

/* Compile `src`, run it in THIS process with stdout captured on a pipe.
 * Writes the module globals back through g[0..ng-1] (caller-sized to 128). */
static void run_src(const char *src, char *out, size_t outsz, PyObject *g[128],
                    uint64_t *ng)
{
    int ok = asm_compile(src);
    if (ok != 0) { CHECK(ok == 0, "compile succeeded"); out[0] = 0; return; }

    uint64_t ncode  = asm_compile_code_len();
    uint64_t *code  = asm_compile_get_code();
    PyObject **consts = asm_compile_get_consts();
    uint64_t nconsts = asm_compile_consts_len();
    uint64_t nglob  = asm_compile_nglobals();
    if (ng) *ng = nglob;
    if (nglob > 128) nglob = 128;

    /* temporarily capture this process's own stdout */
    fflush(stdout);
    int saved = dup(STDOUT_FILENO);
    int pfd[2]; pipe(pfd);
    dup2(pfd[1], STDOUT_FILENO); close(pfd[1]);

    memset(g, 0, nglob * sizeof(PyObject *));
    PyObject *st[128] = {0};
    VmFrame fr;
    memset(&fr, 0, sizeof fr);
    fr.code = code; fr.ncode = ncode;
    fr.consts = consts; fr.nconsts = nconsts;
    fr.globals = g; fr.nglobals = nglob;
    fr.vstack = st; fr.vstack_cap = 128;
    asm_vm_run(&fr);

    fflush(stdout);
    dup2(saved, STDOUT_FILENO); close(saved);
    ssize_t n = read(pfd[0], out, outsz - 1);
    close(pfd[0]);
    if (n < 0) n = 0;
    out[n] = 0;
}

int main(void)
{
    char buf[256];
    PyObject *g[128];

    /* --- 1 & 2: x = 2+3; print x; print x-1  => "5\n4\n" ------------------ */
    {
        uint64_t ng = 0;
        run_src("x = 2 + 3\nprint(x)\nprint(x - 1)\n", buf, sizeof buf, g, &ng);
        CHECK(strcmp(buf, "5\n4\n") == 0,
              "compile+run prints '5\\n4\\n' for x=2+3");
        CHECK(ng == 1, "one global name interned (x)");
        CHECK(g[0] != NULL && asm_int_get_value(g[0]) == 5,
              "module global x holds 5");
        printf("P1 stdout = \"%s\"   global x = %" PRId64 "\n", buf,
               g[0] ? asm_int_get_value(g[0]) : -1);
    }

    /* --- 3: nested parentheses: print((1 + 2) + 4)  => "7\n" -------------- */
    {
        uint64_t ng = 0;
        run_src("print((1 + 2) + 4)\n", buf, sizeof buf, g, &ng);
        CHECK(strcmp(buf, "7\n") == 0, "nested parens compile to 7");
        printf("P2 stdout = \"%s\"\n", buf);
    }

    /* --- 3b: chained +/- evaluates left to right: print(10-3-2) => "5\n" --- */
    {
        uint64_t ng = 0;
        run_src("print(10 - 3 - 2)\n", buf, sizeof buf, g, &ng);
        CHECK(strcmp(buf, "5\n") == 0, "left-assoc 10-3-2 == 5");
        printf("P3 stdout = \"%s\"\n", buf);
    }

    /* --- 4: bare expression statement is discarded ------------------------- */
    {
        uint64_t ng = 0;
        run_src("1 + 1\nprint(9 - 4)\n", buf, sizeof buf, g, &ng);
        CHECK(strcmp(buf, "5\n") == 0,
              "bare '1+1' statement discarded, then prints 5");
        printf("P4 stdout = \"%s\"\n", buf);
    }

    /* --- 5: malformed source is a compile error --------------------------- */
    CHECK(asm_compile("x =\n") == -1, "incomplete assignment is an error");
    CHECK(asm_compile("print(5\n") == -1, "unclosed paren is an error");
    printf("error paths: incomplete assignment and unclosed paren rejected\n");

    if (failures == 0) {
        printf("\nPHASE 8 compiler (source -> VM): ALL CHECKS PASSED\n");
        return EXIT_SUCCESS;
    }
    fprintf(stderr, "\nPHASE 8 compiler (source -> VM): %d check(s) FAILED\n",
            failures);
    return EXIT_FAILURE;
}
