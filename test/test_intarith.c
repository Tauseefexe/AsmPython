/*
 * AsmPython -- Phase 5 validation harness: int arithmetic + cache semantics.
 *
 *  1. a + b returns an object whose value is exactly a+b;
 *  2. when the result is in -5..256 it IS the matching immortal singleton
 *     (2 + 3 === 5, by object identity);
 *  3. out-of-range results are fresh, correctly valued objects;
 *  4. subtraction behaves identically (negation lands on the cache);
 *  5. the operands' references are untouched (we only created the result).
 *
 * Exits 0 on success, prints failures and exits non-zero otherwise.
 */
#include <stdio.h>
#include <stdlib.h>
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

int main(void)
{
    PyObject *two  = asm_int_new(2);
    PyObject *three = asm_int_new(3);

    /* --- 1 & 2: 2 + 3 == 5, and it is THE immortal 5 singleton --------- */
    PyObject *five = asm_int_add(two, three);
    CHECK(five != NULL, "2+3 produced an object");
    CHECK(asm_int_get_value(five) == 5, "2+3 == 5 (value)");
    CHECK(pym_is_smallint(five), "2+3 result is in the small-int cache");
    CHECK(five == asm_int_new(5), "2+3 result IS the 5 singleton");

    /* --- boundary: -5 + 0 == -5 (cached); 3 + 253 == 256 (cached) ------ */
    PyObject *mn = asm_int_sub(asm_int_new(0), asm_int_new(5));
    CHECK(asm_int_get_value(mn) == -5 && pym_is_smallint(mn),
          "0-5 == -5 and is cached");
    PyObject *mx = asm_int_add(asm_int_new(3), asm_int_new(253));
    CHECK(asm_int_get_value(mx) == 256 && pym_is_smallint(mx),
          "3+253 == 256 and is cached");

    /* --- 3: just past the cache -> a fresh, correctly valued object ----- */
    PyObject *over = asm_int_add(asm_int_new(256), asm_int_new(1));   /* 257 */
    CHECK(asm_int_get_value(over) == 257, "256+1 == 257");
    CHECK(!pym_is_smallint(over), "257 is a fresh object, not cached");

    PyObject *under = asm_int_sub(asm_int_new(-5), asm_int_new(1));    /* -6 */
    CHECK(asm_int_get_value(under) == -6, "-5-1 == -6");
    CHECK(!pym_is_smallint(under), "-6 is a fresh object, not cached");

    /* --- larger magnitudes --------------------------------------------- */
    PyObject *bigsum = asm_int_add(asm_int_new(1000000), asm_int_new(2000000));
    CHECK(asm_int_get_value(bigsum) == 3000000, "1e6 + 2e6 == 3e6");
    PyObject *bigdiff = asm_int_sub(asm_int_new(10), asm_int_new(1000000));
    CHECK(asm_int_get_value(bigdiff) == -999990, "10 - 1e6 == -999990");

    /* --- 5: operands are untouched (still hold their own values) -------- */
    CHECK(asm_int_get_value(two) == 2, "operand `2` unchanged after add");
    CHECK(asm_int_get_value(three) == 3, "operand `3` unchanged after add");
    CHECK(two->ob_refcnt >= 1 && three->ob_refcnt >= 1,
          "operand refcounts not corrupted by arithmetic");

    printf("2+3  -> value=%" PRId64 " cached=%d\n",
           asm_int_get_value(five), pym_is_smallint(five));
    printf("256+1-> value=%" PRId64 " cached=%d\n",
           asm_int_get_value(over), pym_is_smallint(over));
    printf("1e6+2e6 -> value=%" PRId64 " cached=%d\n",
           asm_int_get_value(bigsum), pym_is_smallint(bigsum));

    if (failures == 0) {
        printf("\nPHASE 5 int arithmetic + cache: ALL CHECKS PASSED\n");
        return EXIT_SUCCESS;
    }
    fprintf(stderr, "\nPHASE 5 int arithmetic + cache: %d check(s) FAILED\n",
            failures);
    return EXIT_FAILURE;
}
