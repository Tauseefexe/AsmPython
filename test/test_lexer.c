/*
 * AsmPython -- Phase 7 validation harness: the lexer.
 *
 * Tokenises several source strings and asserts the exact token stream each
 * should produce (type, slice location, and integer/operator value), then
 * confirms end-of-input is reported correctly.
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

/* Re-lex `src` from scratch, expecting the given token types. */
static void expect_types(const char *src, const unsigned *types, size_t n)
{
    uint64_t pos = 0;
    LexToken t;
    size_t i = 0;
    for (;;) {
        int r = asm_lex(src, &pos, &t);
        if (i < n) {
            CHECK(r == 0, "got a token before the stream runs out");
            CHECK(t.type == types[i],
                  "token type matches at each position");
        }
        i++;
        if (r == 1) break;
    }
    CHECK(i - 1 == n, "token count matches the expectation");
}

int main(void)
{
    /* --- simple assignment: x = 2 + 3 ------------------------------ */
    {
        const unsigned seq[] = { TOK_NAME, TOK_OP, TOK_INT, TOK_OP, TOK_INT };
        expect_types("x = 2 + 3", seq, 5);
    }
    /* --- leading/trailing whitespace and a multi-char name ---------- */
    /* "  my_var\t=  (10 )-7\n" ->
     *    my_var  =  (  10  )  -  7   = 7 tokens */
    {
        const unsigned seq[] = { TOK_NAME, TOK_OP, TOK_OP, TOK_INT,
                                 TOK_OP, TOK_OP, TOK_INT };
        expect_types("  my_var\t=  (10 )-7\n", seq, 7);
    }
    /* --- print(1000000) --- */
    {
        const unsigned seq[] = { TOK_NAME, TOK_OP, TOK_INT, TOK_OP };
        expect_types("print(1000000)", seq, 4);
    }

    /* --- detailed field checks on one program ----------------------- */
    {
        const char *src = "total = 42 + count3";
        uint64_t pos = 0;
        LexToken t;
        int r;

        r = asm_lex(src, &pos, &t);           /* total     */
        CHECK(r == 0 && t.type == TOK_NAME, "name: total");
        CHECK(t.start == 0 && t.length == 5, "name slice is exactly 'total'");

        r = asm_lex(src, &pos, &t);           /* =         */
        CHECK(r == 0 && t.type == TOK_OP && t.value == '=',
              "operator '=' value correct");

        r = asm_lex(src, &pos, &t);           /* 42        */
        CHECK(r == 0 && t.type == TOK_INT && t.value == 42,
              "integer literal 42 parsed");
        CHECK(t.start == 8 && t.length == 2, "42 slice at offset 8 len 2");

        r = asm_lex(src, &pos, &t);           /* +         */
        CHECK(r == 0 && t.type == TOK_OP && t.value == '+', "operator '+'");

        r = asm_lex(src, &pos, &t);           /* count3    */
        CHECK(r == 0 && t.type == TOK_NAME && t.length == 6,
              "name with embedded digit length 6");
        CHECK(t.start == 13, "count3 slice at offset 13");

        r = asm_lex(src, &pos, &t);           /* EOF       */
        CHECK(r == 1 && t.type == TOK_EOF, "reports end of input");
        CHECK(pos == strlen(src), "pos rests at end of source after EOF");
    }

    /* --- larger integer + parentheses: 999999*7 ---------------------- */
    {
        const char *src = "(999999 * 7)";
        uint64_t pos = 0;
        LexToken t;
        asm_lex(src, &pos, &t);               /* ( */
        CHECK(t.type == TOK_OP && t.value == '(', "lparen");
        asm_lex(src, &pos, &t);               /* 999999 */
        CHECK(t.type == TOK_INT && t.value == 999999, "int 999999");
        asm_lex(src, &pos, &t);               /* * */
        CHECK(t.type == TOK_OP && t.value == '*', "star");
        asm_lex(src, &pos, &t);               /* 7 */
        CHECK(t.type == TOK_INT && t.value == 7, "int 7");
        asm_lex(src, &pos, &t);               /* ) */
        CHECK(t.type == TOK_OP && t.value == ')', "rparen");
    }

    if (failures == 0) {
        printf("\nPHASE 7 lexer: ALL CHECKS PASSED\n");
        return EXIT_SUCCESS;
    }
    fprintf(stderr, "\nPHASE 7 lexer: %d check(s) FAILED\n", failures);
    return EXIT_FAILURE;
}
