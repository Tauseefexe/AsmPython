/*
 * AsmPython -- Phase 2 validation harness: reference counting.
 *
 * Exercises asm_incref / asm_decref against objects created with the built-in
 * "object" type (whose dealloc recycles slots via asm_pyobject_free):
 *   1. a fresh object starts at ob_refcnt == 1;
 *   2. INCREF raises the count by exactly 1;
 *   3. DECREF while still > 1 lowers it by 1 and reports "alive";
 *   4. the final DECREF deallocates the object and reports "deallocated";
 *   5. the freed slot is recycled: the very next creation reuses that address
 *      and does NOT grow the arena;
 *   6. the built-in type object exposes its name and dealloc slot correctly.
 *
 * Exits 0 on success, prints failures and exits non-zero otherwise.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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
    /* --- 6: built-in type object is wired up correctly --- */
    CHECK(strcmp(asm_object_type.name, "object") == 0,
          "asm_object_type.name == \"object\"");
    CHECK(asm_object_type.dealloc == asm_pyobject_free,
          "asm_object_type.dealloc == asm_pyobject_free");

    /* create one object of the built-in type */
    PyObject *o = asm_pyobject_new(&asm_object_type);
    CHECK(o != NULL, "object allocated");
    CHECK(o->ob_type == (void *)&asm_object_type, "ob_type installed");
    if (o == NULL)
        goto done;

    /* --- 1: fresh object has exactly one reference --- */
    CHECK(o->ob_refcnt == 1, "fresh object refcnt == 1");

    /* --- 2: INCREF bumps the count --- */
    asm_incref(o);
    CHECK(o->ob_refcnt == 2, "after INCREF refcnt == 2");
    asm_incref(o);
    CHECK(o->ob_refcnt == 3, "after 2x INCREF refcnt == 3");

    /* --- 3: DECREF above 1 keeps it alive --- */
    CHECK(asm_decref(o) == 0, "first DECREF reports alive");
    CHECK(o->ob_refcnt == 2, "after DECREF refcnt == 2");
    CHECK(asm_decref(o) == 0, "second DECREF reports alive");
    CHECK(o->ob_refcnt == 1, "after 2x DECREF refcnt == 1");

    /* --- 4: the last DECREF deallocates the object --- */
    uintptr_t arena_before_free = pymem_ahead;   /* snapshot the arena        */
    CHECK(asm_decref(o) == 1, "final DECREF reports deallocated");
    CHECK(o->ob_refcnt == 0, "deallocated object refcnt == 0");

    /* --- 5: the slot is recycled without growing the arena --- */
    PyObject *o2 = asm_pyobject_new(&asm_object_type);
    CHECK(o2 != NULL, "recycled object allocated");
    if (o2 == NULL)
        goto done;
    CHECK(o2 == o, "new object reuses the freed slot (same address)");
    CHECK(pymem_ahead == arena_before_free,
          "recycling did not grow the arena");
    CHECK(free_lists[0] == 0, "object-class free list empty after reuse");
    CHECK(o2->ob_refcnt == 1, "recycled object starts at refcnt == 1");
    CHECK(o2->ob_type == (void *)&asm_object_type, "recycled ob_type installed");
    CHECK(asm_decref(o2) == 1, "recycled object deallocated cleanly");

    /* a chained second recycle still works (free list stays consistent) */
    PyObject *a = asm_pyobject_new(&asm_object_type);
    PyObject *b = asm_pyobject_new(&asm_object_type);
    CHECK(a && b, "two objects allocated for chained recycle");
    if (a && b) {
        asm_decref(b);                       /* b goes on the list           */
        PyObject *again = asm_pyobject_new(&asm_object_type);
        CHECK(again == b, "free list is LIFO: next reuse takes b's slot");
        if (again) asm_decref(again);
        asm_decref(a);                       /* a goes on the list           */
        PyObject *last = asm_pyobject_new(&asm_object_type);
        CHECK(last == a, "later reuse takes a's slot");
        if (last) asm_decref(last);
    }

    printf("phase 2 refcount + free-list reuse: all checks exercised\n");

done:
    if (failures == 0) {
        printf("\nPHASE 2 reference counting: ALL CHECKS PASSED\n");
        return EXIT_SUCCESS;
    }
    fprintf(stderr, "\nPHASE 2 reference counting: %d check(s) FAILED\n",
            failures);
    return EXIT_FAILURE;
}
