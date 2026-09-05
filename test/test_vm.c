/*
 * AsmPython -- Phase 6 validation harness: the bytecode virtual machine.
 *
 * Hand-assembles CPython-style instruction streams and runs them through
 * asm_vm_run(), asserting observable behaviour. Because PRINT consumes the
 * value it shows (like CPython), a program either RETURNs a value OR PRINTs
 * one -- never both with the same operand.
 *
 *   1. arithmetic chain computes 6 and leaves it as frame->result;
 *   2. STORE_GLOBAL / LOAD_GLOBAL round-trip an owned reference (a == 7);
 *   3. PRINT emits the exact decimal to stdout (captured through a pipe);
 *   4. subtraction through global round-trip yields 4.
 *
 * Exits 0 on success, prints failures and exits non-zero otherwise.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include <inttypes.h>

#include "../include/asmpython.h"

static int failures = 0;

#define CHECK(cond, msg)                                                \
    do {                                                                \
        if (!(cond)) {                                                  \
            fprintf(stderr, "FAIL [%s] at %s:%d\n", msg, __FILE__, __LINE__); \
            failures++;                                                 \
        }                                                               \
    } while (0)

static void run_once(uint64_t *code, uint64_t ncode, PyObject **consts,
                     uint64_t nconsts, PyObject **globals, PyObject **stack,
                     VmFrame *out)
{
    memset(out, 0, sizeof *out);
    out->code = code; out->ncode = ncode;
    out->consts = consts; out->nconsts = nconsts;
    out->globals = globals; out->nglobals = 8;
    out->vstack = stack; out->vstack_cap = 64;
    asm_vm_run(out);
}

int main(void)
{
    /* constant pool: 1,2,3,7 */
    PyObject *c[4] = { asm_int_new(1), asm_int_new(2),
                       asm_int_new(3), asm_int_new(7) };

    /* --- program A: (2+3)+1 -> RETURN 6 --------------------------------- */
    uint64_t pa[] = {
        vm_insn(VMOP_LOAD_CONST, 1),   /* 2 */
        vm_insn(VMOP_LOAD_CONST, 2),   /* 3 */
        vm_insn(VMOP_BINARY_ADD, 0),   /* 5 */
        vm_insn(VMOP_LOAD_CONST, 0),   /* 1 */
        vm_insn(VMOP_BINARY_ADD, 0),   /* 6 */
        vm_insn(VMOP_RETURN_VALUE, 0),
    };
    {
        PyObject *g[8] = {0}, *st[64] = {0}; VmFrame fr;
        run_once(pa, 6, c, 4, g, st, &fr);
        CHECK(fr.result != NULL, "program A produced a result");
        if (fr.result) {
            CHECK(asm_int_get_value(fr.result) == 6, "program A == 6");
            CHECK(fr.result == asm_int_new(6),
                  "program A result is the 6 singleton");
        }
        printf("program A result = %" PRId64 "\n",
               fr.result ? asm_int_get_value(fr.result) : -9999);
    }

    /* --- program B: a = 7; result = a - 3  => 4 -------------------------- */
    uint64_t pb[] = {
        vm_insn(VMOP_LOAD_CONST, 3),      /* 7 */
        vm_insn(VMOP_STORE_GLOBAL, 0),    /* a = 7 */
        vm_insn(VMOP_LOAD_GLOBAL, 0),     /* a */
        vm_insn(VMOP_LOAD_CONST, 2),      /* 3 */
        vm_insn(VMOP_BINARY_SUB, 0),      /* a - 3 = 4 */
        vm_insn(VMOP_RETURN_VALUE, 0),
    };
    {
        PyObject *g[8] = {0}, *st[64] = {0}; VmFrame fr;
        run_once(pb, 6, c, 4, g, st, &fr);
        CHECK(g[0] != NULL, "program B stored a global");
        if (g[0]) CHECK(asm_int_get_value(g[0]) == 7, "global a == 7");
        if (fr.result)
            CHECK(asm_int_get_value(fr.result) == 4, "program B result == 4");
        printf("program B: a=%" PRId64 " result=%" PRId64 "\n",
               g[0] ? asm_int_get_value(g[0]) : -1,
               fr.result ? asm_int_get_value(fr.result) : -1);
    }

    /* --- program C (capture): print 7 + 8? (no 8); print 7 => "7\n" ------
     *   Use consts 0..: just print 7 directly. Ends by returning a dummy. */
    uint64_t pc7[] = {
        vm_insn(VMOP_LOAD_CONST, 3),      /* 7 */
        vm_insn(VMOP_PRINT, 0),           /* -> "7\n" */
        vm_insn(VMOP_LOAD_CONST, 0),      /* dummy 1 to return */
        vm_insn(VMOP_RETURN_VALUE, 0),
    };
    {
        /* capture stdout in a child */
        int pfd[2]; pipe(pfd);
        pid_t pid = fork();
        if (pid == 0) {
            dup2(pfd[1], STDOUT_FILENO); close(pfd[0]); close(pfd[1]);
            PyObject *g[8] = {0}, *st[64] = {0}; VmFrame fr;
            run_once(pc7, 4, c, 4, g, st, &fr);
            _exit(0);
        }
        close(pfd[1]);
        char buf[128]; ssize_t n = read(pfd[0], buf, sizeof buf - 1);
        close(pfd[0]); waitpid(pid, NULL, 0);
        buf[n < 0 ? 0 : n] = '\0';
        CHECK(strcmp(buf, "7\n") == 0, "print 7 emits exactly \"7\\n\"");
        printf("program C stdout = \"%s\"\n", buf);
    }

    /* --- program D (capture): a=7; print(a-3) => "4\n" ------------------ */
    uint64_t pd[] = {
        vm_insn(VMOP_LOAD_CONST, 3),      /* 7 */
        vm_insn(VMOP_STORE_GLOBAL, 0),    /* a = 7 */
        vm_insn(VMOP_LOAD_GLOBAL, 0),     /* a */
        vm_insn(VMOP_LOAD_CONST, 2),      /* 3 */
        vm_insn(VMOP_BINARY_SUB, 0),      /* a-3 = 4 */
        vm_insn(VMOP_PRINT, 0),           /* -> "4\n" */
        vm_insn(VMOP_LOAD_CONST, 0),
        vm_insn(VMOP_RETURN_VALUE, 0),
    };
    {
        int pfd[2]; pipe(pfd);
        pid_t pid = fork();
        if (pid == 0) {
            dup2(pfd[1], STDOUT_FILENO); close(pfd[0]); close(pfd[1]);
            PyObject *g[8] = {0}, *st[64] = {0}; VmFrame fr;
            run_once(pd, 8, c, 4, g, st, &fr);
            _exit(0);
        }
        close(pfd[1]);
        char buf[128]; ssize_t n = read(pfd[0], buf, sizeof buf - 1);
        close(pfd[0]); waitpid(pid, NULL, 0);
        buf[n < 0 ? 0 : n] = '\0';
        CHECK(strcmp(buf, "4\n") == 0, "print a-3 emits exactly \"4\\n\"");
        printf("program D stdout = \"%s\"\n", buf);
    }

    if (failures == 0) {
        printf("\nPHASE 6 bytecode VM: ALL CHECKS PASSED\n");
        return EXIT_SUCCESS;
    }
    fprintf(stderr, "\nPHASE 6 bytecode VM: %d check(s) FAILED\n", failures);
    return EXIT_FAILURE;
}
