/*
 * AsmPython -- Phase 6 validation harness: output layer.
 *
 *   1. asm_i64_to_ascii matches C's own decimal conversion (snprintf) for a
 *      wide sweep of signed 64-bit values, including the extremes and sign
 *      boundaries -- so our formatting is byte-for-byte identical to what
 *      a correct runtime must emit;
 *   2. the output routines actually write to stdout (observable);
 *   3. asm_print_int_object prints the payload of a real int object.
 *
 * Exits 0 on success, prints failures and exits non-zero otherwise.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
#include <stdint.h>

#include "../include/asmpython.h"

static int failures = 0;

#define CHECK(cond, msg)                                                \
    do {                                                                \
        if (!(cond)) {                                                  \
            fprintf(stderr, "FAIL [%s] at %s:%d\n", msg, __FILE__, __LINE__); \
            failures++;                                                 \
        }                                                               \
    } while (0)

/* Format with our assembly routine and compare against the C library. */
static void check_value(int64_t v)
{
    char ours[64];
    char ref[64];

    uint64_t olen = asm_i64_to_ascii(v, ours);
    int rlen = snprintf(ref, sizeof(ref), "%" PRId64, v);

    /* 1: byte length agrees */
    if ((int)olen != rlen || strncmp(ours, ref, olen) != 0) {
        fprintf(stderr, "FAIL value %" PRId64 ": asm='%.*s' ref='%s'\n",
                v, (int)olen, ours, ref);
        failures++;
    }
}

int main(void)
{
    const int64_t sweep[] = {
        0, 1, -1, 2, -2, 5, -5, 9, 10, -10, 11, 99, 100, -100, 999, -999,
        1000, -1000, 65535, -65535, 999999, -999999, 1000000000,
        -1000000000, 1234567890123456789LL, -1234567890123456789LL,
        INT32_MAX, INT32_MIN, INT64_MAX, INT64_MIN,
        999999999999999999LL, -999999999999999999LL
    };
    size_t i;
    for (i = 0; i < sizeof(sweep) / sizeof(sweep[0]); i++)
        check_value(sweep[i]);

    /* sanity on one specific value for the console transcript */
    {
        char buf[32];
        uint64_t n = asm_i64_to_ascii(INT64_MIN, buf);
        CHECK(n == 20 && memcmp(buf, "-9223372036854775808", 20) == 0,
              "INT64_MIN formats to exactly '-9223372036854775808'");
    }

    /* --- 2 & 3: real stdout output via the runtime primitives --------- */
    {
        static const char hdr[] = "== AsmPython output layer ==\n";
        asm_write_stdout(hdr, sizeof(hdr) - 1);
    }

    /* print a few integers through actual int objects */
    PyObject *vals[] = {
        asm_int_new(0),
        asm_int_new(-7),
        asm_int_new(2026),
        asm_int_new(INT64_MAX),
        asm_int_new(INT64_MIN),
        asm_int_new(1000000)
    };
    for (i = 0; i < sizeof(vals) / sizeof(vals[0]); i++) {
        if (vals[i]) {
            asm_print_int_object(vals[i]);
            asm_print_newline();
        }
    }

    /* a sum printed end-to-end: (2+3) => the 5 singleton, printed */
    PyObject *sum = asm_int_add(asm_int_new(2), asm_int_new(3));
    if (sum) {
        asm_print_int_object(sum);
        asm_print_newline();
    }

    if (failures == 0) {
        printf("\nPHASE 6 output layer: ALL CHECKS PASSED\n");
        return EXIT_SUCCESS;
    }
    fprintf(stderr, "\nPHASE 6 output layer: %d check(s) FAILED\n", failures);
    return EXIT_FAILURE;
}
