/*
 * AsmPython -- Phase 3 validation harness: size-class object allocator.
 *
 * Uses asm_pyobject_new/asm_pyobject_free with C-side type objects that carry
 * distinct basic_size footprints and asserts that:
 *   1. objects land in the size class implied by basic_size;
 *   2. a freed object of size S is recycled by the next same-S allocation;
 *   3. recycling is size-exact: a freed 64-byte object is NEVER handed to a
 *      32-byte request (no cross-class aliasing), and vice-versa;
 *   4. same-size slots are contiguous in the arena when freshly carved;
 *   5. asm_pyobject_free reaches the right free-list bucket per size.
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

/* Two concrete, distinct types with different instance footprints. */
static PyTypeObject type32 = { "type32", asm_pyobject_free, 32 };
static PyTypeObject type64 = { "type64", asm_pyobject_free, 64 };

int main(void)
{
    /* --- 1: allocate three size-32 objects, contiguous 16-byte slots --- */
    PyObject *a = asm_pyobject_new(&type32);
    PyObject *b = asm_pyobject_new(&type32);
    PyObject *c = asm_pyobject_new(&type32);
    CHECK(a && b && c, "three size-32 objects allocated");
    if (!(a && b && c))
        goto done;
    CHECK((uintptr_t)b == (uintptr_t)a + 32, "32B slot b sits after a");
    CHECK((uintptr_t)c == (uintptr_t)b + 32, "32B slot c sits after b");
    CHECK(pymem_aligned(a) && pymem_aligned(b) && pymem_aligned(c),
          "size-32 objects 16-byte aligned");
    CHECK(a->ob_type == (void *)&type32, "ob_type is type32");

    /* --- 2: free b (middle); a fresh 32-byte request reuses b's address --- */
    uintptr_t baddr = (uintptr_t)b;
    asm_pyobject_free(b);
    CHECK(free_lists[1] == baddr, "b is on the 32-byte bucket (index 1)");
    PyObject *a2 = asm_pyobject_new(&type32);
    CHECK(a2 == b, "32-byte allocation reuses the freed slot");
    CHECK(free_lists[1] == 0, "bucket drained after reuse");
    if (a2) asm_pyobject_free(a2);               /* park it again              */

    /* --- 3: cross-type isolation --------------------------------------- */
    PyObject *big = asm_pyobject_new(&type64);   /* goes to bucket index 3     */
    CHECK(big != NULL, "size-64 object allocated");
    if (big == NULL)
        goto done;
    CHECK(big->ob_type == (void *)&type64, "ob_type is type64");

    asm_pyobject_free(big);                      /* 64-byte slot freed        */
    CHECK(free_lists[3] == (uintptr_t)big, "64-byte bucket holds big");
    CHECK(free_lists[1] != 0,
          "32-byte bucket independently holds its own slot");

    /* A size-32 request must ignore the free 64-byte object (bucket 3). */
    PyObject *small = asm_pyobject_new(&type32);
    CHECK(small != NULL, "size-32 allocation still succeeds");
    if (small) {
        CHECK(small != big, "size-32 request did NOT steal the 64-byte slot");
        CHECK(small == b, "size-32 request reused the 32-byte slot (b)");
        asm_pyobject_free(small);
    }
    /* And a size-64 request must reuse the 64-byte slot, not the 32's.    */
    PyObject *big2 = asm_pyobject_new(&type64);
    CHECK(big2 == big, "size-64 request reused the 64-byte slot");

    printf("32B slots: %#" PRIxPTR " %#" PRIxPTR " %#" PRIxPTR "\n",
           (uintptr_t)a, (uintptr_t)b, (uintptr_t)c);
    printf("64B slot : %#" PRIxPTR "\n", (uintptr_t)big);
    printf("free-list heads after test: bucket1=%#" PRIxPTR
           " bucket3=%#" PRIxPTR "\n", free_lists[1], free_lists[3]);

done:
    if (failures == 0) {
        printf("\nPHASE 3 size-class allocator: ALL CHECKS PASSED\n");
        return EXIT_SUCCESS;
    }
    fprintf(stderr, "\nPHASE 3 size-class allocator: %d check(s) FAILED\n",
            failures);
    return EXIT_FAILURE;
}
