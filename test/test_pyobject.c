/*
 * AsmPython -- Phase 1 validation harness.
 *
 * Calls asm_pyobject_new() and asm_raw_alloc() from src/pyobject.S and
 * asserts every property we promised for the PyObject core:
 *   1. a non-NULL, non-zero object is returned;
 *   2. ob_refcnt == 1 on every fresh object;
 *   3. ob_type points back to exactly the type pointer we passed in;
 *   4. returned addresses are 16-byte aligned;
 *   5. two allocations never alias (each gets its own 16-byte slot);
 *   6. the arena bump pointer advances by exactly one slot per object.
 *
 * Exits 0 on success, prints the failure and exits non-zero otherwise.
 */
#include <stdio.h>
#include <stdlib.h>
#include <inttypes.h>

#include "../include/asmpython.h"

/* Two concrete, distinct type objects so we can prove ob_type round-trips. */
static PyTypeObject type_int = { "int", asm_pyobject_free, PY_OBJECT_SIZE };
static PyTypeObject type_str = { "str", asm_pyobject_free, PY_OBJECT_SIZE };

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
    /* --- 3a/3b: two fresh objects of two different "types" --- */
    PyObject *o1 = asm_pyobject_new(&type_int);
    uintptr_t mark = pymem_ahead;               /* arena right after o1       */
    PyObject *o2 = asm_pyobject_new(&type_str);
    (void)mark;

    CHECK(o1 != NULL, "o1 allocated");
    CHECK(o2 != NULL, "o2 allocated");
    if (o1 == NULL || o2 == NULL)
        goto done;

    /* 1 & 4: aligned, non-zero addresses */
    CHECK(pymem_aligned(o1), "o1 16-byte aligned");
    CHECK(pymem_aligned(o2), "o2 16-byte aligned");

    /* 2: reference counts are exactly 1 */
    CHECK(o1->ob_refcnt == 1, "o1 refcnt == 1");
    CHECK(o2->ob_refcnt == 1, "o2 refcnt == 1");

    /* 3: type pointers installed verbatim */
    CHECK(o1->ob_type == (void *)&type_int, "o1 ob_type == &type_int");
    CHECK(o2->ob_type == (void *)&type_str, "o2 ob_type == &type_str");

    /* 5: distinct slots, o2 exactly one slot above o1 (contiguous bump) */
    CHECK(o1 != o2, "o1 and o2 are distinct objects");
    CHECK((uintptr_t)o2 == (uintptr_t)o1 + PY_OBJECT_SIZE,
          "o2 sits exactly one slot after o1");

    /* 6: a single object bumped the arena by exactly one 16-byte slot */
    CHECK(pymem_ahead == mark + PY_OBJECT_SIZE,
          "one object advanced the arena by exactly one slot");

    printf("o1 @ %#" PRIxPTR "  refcnt=%" PRIu64 "  type=%p\n",
           (uintptr_t)o1, o1->ob_refcnt, o1->ob_type);
    printf("o2 @ %#" PRIxPTR "  refcnt=%" PRIu64 "  type=%p\n",
           (uintptr_t)o2, o2->ob_refcnt, o2->ob_type);

    /* --- 3a: raw allocator honours large, awkward sizes --- */
    void *big = asm_raw_alloc(3000);            /* crosses page boundary?      */
    CHECK(big != NULL, "raw alloc 3000 bytes");
    if (big) {
        CHECK(pymem_aligned(big), "big 16-byte aligned");
        /* the bump pointer must have advanced past `big`'s slot */
        CHECK(pymem_ahead >= (uintptr_t)big + 3000,
              "arena advanced past 3000-byte object");
        printf("raw 3000B @ %#" PRIxPTR "\n", (uintptr_t)big);
    }

    /* --- the arena ceiling stays put on the fast path (same chunk) --- */
    {   uintptr_t top = pymem_atop;
        void *more = asm_raw_alloc(64);
        CHECK(more != NULL && pymem_atop == top,
              "fast-path allocation does not remap (ceiling unchanged)");
    }

    /* --- force the slow path: a request larger than the initial chunk --- */
    void *huge = asm_raw_alloc(128u * 1024u);   /* 128 KiB > 64 KiB chunk      */
    CHECK(huge != NULL, "raw alloc 128 KiB (forces mmap growth)");
    if (huge) {
        CHECK(pymem_aligned(huge), "huge 16-byte aligned");
        /* a fresh chunk was mapped, so `huge` lives outside the old arena     */
        CHECK(pymem_atop >= (uintptr_t)huge + 128u * 1024u,
              "huge chunk ceiling covers the request");
        printf("raw 128KiB @ %#" PRIxPTR " (new chunk top %#" PRIxPTR ")\n",
               (uintptr_t)huge, pymem_atop);
    }

    printf("allocator state after test: ahead=%#" PRIxPTR " atop=%#" PRIxPTR
           "\n", pymem_ahead, pymem_atop);

done:
    if (failures == 0) {
        printf("\nPHASE 1 PyObject core: ALL CHECKS PASSED\n");
        return EXIT_SUCCESS;
    }
    fprintf(stderr, "\nPHASE 1 PyObject core: %d check(s) FAILED\n", failures);
    return EXIT_FAILURE;
}
