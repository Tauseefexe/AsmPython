/*
 * AsmPython -- Phase 4 validation harness: the int type + small-int cache.
 *
 * Verifies the CPython behaviours:
 *   1. ints in [-5, 256] are immortal singletons: repeated requests return
 *      the SAME pointer, which lives inside the static cache;
 *   2. out-of-range values (-6, 257, huge) are fresh objects whose type is
 *      pym_int_type and whose payload value round-trips;
 *   3. fresh ints are reference-counted and recycled: once dropped they are
 *      reused by the next fresh int, so the arena does not keep growing;
 *   4. the cached singletons are immortal even if dropped to zero (their
 *      dealloc is a no-op);
 *   5. value <-> object mapping is exact (get_value returns what new took).
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
    /* --- type object sanity --- */
    CHECK(pym_int_type.basic_size == PYM_INT_SIZE, "int basic_size == 24");
    CHECK(pym_int_type.dealloc == asm_int_dealloc,
          "int dealloc is the immortal-aware free");

    /* --- 1: cached singletons ------------------------------------------ */
    PyObject *a = asm_int_new(5);
    PyObject *b = asm_int_new(5);
    CHECK(a != NULL && b != NULL, "small ints allocated");
    CHECK(a == b, "small int 5 is a singleton (same object)");
    CHECK(pym_is_smallint(a), "small int 5 lives in the cache");
    CHECK(a->ob_type == (void *)&pym_int_type, "small int ob_type == int");

    PyObject *neg = asm_int_new(PYM_INT_MIN);     /* -5 */
    PyObject *big = asm_int_new(PYM_INT_MAX);     /* 256 */
    CHECK(pym_is_smallint(neg), "-5 is cached");
    CHECK(pym_is_smallint(big), "256 is cached");
    CHECK(asm_int_get_value(neg) == PYM_INT_MIN, "get_value(-5) == -5");
    CHECK(asm_int_get_value(big) == PYM_INT_MAX, "get_value(256) == 256");

    /* --- 2/5: out-of-range values are real, fresh objects --------------- */
    PyObject *lo  = asm_int_new(PYM_INT_MIN - 1);      /* -6 */
    PyObject *hi  = asm_int_new(PYM_INT_MAX + 1);      /* 257 */
    PyObject *huge = asm_int_new(1000000);
    CHECK(lo && hi && huge, "out-of-range ints allocated");
    CHECK(!pym_is_smallint(lo), "-6 is NOT cached");
    CHECK(!pym_is_smallint(hi), "257 is NOT cached");
    CHECK(!pym_is_smallint(huge), "huge int is NOT cached");
    if (lo && hi && huge) {
        CHECK(asm_int_get_value(lo) == -6, "get_value(-6) == -6");
        CHECK(asm_int_get_value(hi) == 257, "get_value(257) == 257");
        CHECK(asm_int_get_value(huge) == 1000000, "get_value(1e6) == 1e6");
        CHECK(lo->ob_type == (void *)&pym_int_type && huge->ob_type
              == (void *)&pym_int_type, "fresh ints are typed int");
    }

    /* --- 3: fresh ints are reference-counted and recycled --------------- */
    uintptr_t arena_at_hi = pymem_ahead;
    /* keep `lo` alive; drop `hi` and `huge` -> back on the 32-byte list */
    asm_decref(hi);
    asm_decref(huge);
    PyObject *next = asm_int_new(12345);
    CHECK(next != NULL, "next fresh int allocated");
    CHECK(!pym_is_smallint(next), "next fresh int is a real object");
    /* it must have reused one of the just-freed slots (same size class) */
    CHECK(next == hi || next == huge,
          "fresh int recycled a slot from the same size class");
    CHECK(asm_int_get_value(next) == 12345, "recycled int stores 12345");
    CHECK(pymem_ahead == arena_at_hi,
          "recycling did not grow the arena");

    /* --- 4: cached ints are immortal even when dropped to zero --------- */
    uintptr_t cache_addr = (uintptr_t)asm_int_new(PYM_INT_MAX);
    PyObject *tmp = (PyObject *)cache_addr;
    /* manufacture a drop to zero: new() incref'd it; drive to zero */
    asm_decref(tmp);                 /* back to base */
    asm_decref(tmp);                 /* 0 -> dealloc guarded, immortal */
    asm_decref(tmp);                 /* stays 0, still not freed */
    CHECK(tmp->ob_type == (void *)&pym_int_type, "immortal int type intact");
    CHECK(asm_int_get_value(tmp) == PYM_INT_MAX, "immortal int value intact");
    CHECK(pym_is_smallint(tmp), "immortal int still inside the cache");
    /* a fresh request still returns the very same singleton */
    PyObject *again = asm_int_new(PYM_INT_MAX);
    CHECK(again == tmp, "cache singleton returned again after drop");

    printf("small int  5   @ %#" PRIxPTR "\n", (uintptr_t)a);
    printf("small int -5   @ %#" PRIxPTR "\n", (uintptr_t)neg);
    printf("small int 256  @ %#" PRIxPTR "\n", (uintptr_t)big);
    printf("fresh int 1e6  @ %#" PRIxPTR "\n", (uintptr_t)huge);
    printf("cache base     @ %#" PRIxPTR "\n", (uintptr_t)pym_smallint_cache);

    if (failures == 0) {
        printf("\nPHASE 4 int type + small-int cache: ALL CHECKS PASSED\n");
        return EXIT_SUCCESS;
    }
    fprintf(stderr, "\nPHASE 4 int type + small-int cache: %d check(s) FAILED\n",
            failures);
    return EXIT_FAILURE;
}
