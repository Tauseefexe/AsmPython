/*
 * AsmPython -- Phase 10 validation harness: singletons + comparisons.
 *
 *   1. asm_int_eq/ne/lt/gt return the immortal True/False singletons;
 *   2. asm_bool_new maps truthiness to True/False;
 *   3. the compiler + VM print bools and None: print(2<3) -> "True";
 *   4. comparisons compose with assignment and arithmetic.
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

static void run_src(const char *src, char *out, size_t outsz)
{
    if (asm_compile(src) != 0) { out[0] = 0; return; }
    uint64_t ncode = asm_compile_code_len();
    uint64_t *code = asm_compile_get_code();
    PyObject **consts = asm_compile_get_consts();
    uint64_t nglob = asm_compile_nglobals();
    PyObject g[128]; memset(g, 0, sizeof g);
    PyObject st[128]; memset(st, 0, sizeof st);
    VmFrame fr; memset(&fr, 0, sizeof fr);
    fr.code = code; fr.ncode = ncode; fr.consts = consts;
    fr.nconsts = asm_compile_consts_len();
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
    /* --- 1: comparisons return the True/False singletons ---------------- */
    PyObject *a2 = asm_int_new(2), *a3 = asm_int_new(3);
    CHECK(asm_int_lt(a2, a3) == &pym_True, "2<3 is the True singleton");
    CHECK(asm_int_gt(a2, a3) == &pym_False, "2>3 is the False singleton");
    CHECK(asm_int_eq(a2, a3) == &pym_False, "2==3 is False");
    CHECK(asm_int_ne(a2, a3) == &pym_True, "2!=3 is True");
    CHECK(asm_int_eq(a2, asm_int_new(2)) == &pym_True, "2==2 is True");

    /* --- 2: asm_bool_new maps truthiness -------------------------------- */
    CHECK(asm_bool_new(0) == &pym_False, "bool(0) == False");
    CHECK(asm_bool_new(1) == &pym_True, "bool(1) == True");
    CHECK(asm_bool_value(&pym_True) == 1 && asm_bool_value(&pym_False) == 0,
          "bool_value round-trips");

    /* --- 3 & 4: compile+run prints booleans and None -------------------- */
    char buf[256];
    run_src("print(2 < 3)\n", buf, sizeof buf);
    CHECK(strcmp(buf, "True\n") == 0, "print(2<3) -> 'True\\n'");

    run_src("print(10 == 10)\n", buf, sizeof buf);
    CHECK(strcmp(buf, "True\n") == 0, "print(10==10) -> True");

    run_src("print(5 > 9)\n", buf, sizeof buf);
    CHECK(strcmp(buf, "False\n") == 0, "print(5>9) -> False");

    run_src("print(4 != 4)\n", buf, sizeof buf);
    CHECK(strcmp(buf, "False\n") == 0, "print(4!=4) -> False");

    run_src("print(None)\n", buf, sizeof buf);
    CHECK(strcmp(buf, "None\n") == 0, "print(None) -> 'None\\n'");

    run_src("print(True)\n", buf, sizeof buf);
    CHECK(strcmp(buf, "True\n") == 0, "print(True) -> 'True\\n'");

    /* comparison result assigned to a variable and printed */
    run_src("x = 2 < 3\nprint(x)\n", buf, sizeof buf);
    CHECK(strcmp(buf, "True\n") == 0, "x = 2<3 ; print(x) -> True");

    /* comparison with an arithmetic side */
    run_src("print((2 + 1) > 2)\n", buf, sizeof buf);
    CHECK(strcmp(buf, "True\n") == 0, "print((2+1)>2) -> True");

    printf("singletons + comparisons validated end-to-end\n");

    if (failures == 0) {
        printf("\nPHASE 10 singletons + comparisons: ALL CHECKS PASSED\n");
        return EXIT_SUCCESS;
    }
    fprintf(stderr, "\nPHASE 10 singletons + comparisons: %d check(s) FAILED\n",
            failures);
    return EXIT_FAILURE;
}
