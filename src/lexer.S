/* ============================================================================
 *  AsmPython  --  a from-scratch CPython clone in x86-64 assembly.
 *
 *  FILE    : src/lexer.S
 *  PHASE   : 7  (THE LEXER -- SOURCE TEXT -> TOKENS)
 *  PURPOSE : First stage of turning Python source into behaviour. The lexer
 *            walks a NUL-terminated source string and hands out one token at a
 *            time, so a parser can pull tokens without knowing about the raw
 *            text. (The virtual machine of Phase 6 already knows how to EXECUTE;
 *            the lexer here is the first half of the front-end that will later
 *            FEED it.)
 *
 *  TOKEN STREAM   (one call per token)
 *      int asm_lex(const char *src, uint64_t *pos, LexToken *out)
 *          * `src` is the whole NUL-terminated program text.
 *          * `pos` holds the byte offset of the next character to read; the
 *            lexer updates it after every token so successive calls continue
 *            where the previous one stopped. Callers start *pos = 0.
 *          * `out` receives a LexToken describing the next token.
 *          * Returns 0 when a token was produced, 1 at end-of-input (out has
 *            type TOK_EOF), or -1 on an error.
 *
 *  RECOGNISED INPUT
 *      - whitespace (space, tab, LF, CR) is skipped between tokens;
 *      - integer literals      -> TOK_INT   (parsed value in .value);
 *      - identifiers/keywords  -> TOK_NAME  (location as [start, length) slice,
 *                                  so 'print', variable names etc. all arrive
 *                                  as names and are classified by the parser);
 *      - any other non-NUL char -> TOK_OP    (its byte code in .value; this
 *                                  covers + - * / = ( ) [ ] , : < > . etc.).
 *
 *  LexToken layout (32 bytes), MUST match include/asmpython.h:
 *      +0  type    (uint64)
 *      +8  start   (uint64)  byte offset of the token within src
 *      +16 length  (uint64)  number of source bytes the token spans
 *      +24 value   (uint64)  parsed integer (TOK_INT) / char code (TOK_OP)
 *
 *  ABI/ASSEMBLER : System V AMD64; GNU as Intel syntax. This routine makes no
 *                  calls, so only caller-saved registers (rax,rcx,rdx,rsi,
 *                  rdi,r8,r9,r10,r11) are used -- no prologue/epilogue needed.
 * ==========================================================================*/

    .intel_syntax noprefix

/* LexToken field offsets. */
    .equ LEX_OFF_TYPE,   0
    .equ LEX_OFF_START,  8
    .equ LEX_OFF_LENGTH, 16
    .equ LEX_OFF_VALUE,  24

/* Token type constants -- MUST match include/asmpython.h. */
    .equ TOK_EOF,   0
    .equ TOK_INT,   1
    .equ TOK_NAME,  2
    .equ TOK_OP,    3
    .equ TOK_STR,   4

/* ASCII helpers. */
    .equ ASCII_NL,  10
    .equ ASCII_CR,  13

/* ============================================================================
 *  1.  REGISTER MAP for asm_lex
 * ----------------------------------------------------------------------------
 *   rdi = src base (NUL-terminated text, kept whole time)
 *   rsi = pos pointer (points at the current-offset u64 in caller memory)
 *   rdx = out (LexToken* to fill)
 *   rcx = character cursor (src + current offset)
 *   r8  = current character (reloaded as needed)
 *   r9  = start pointer of the token currently being scanned
 *   r10 = token start offset (= r9 - rdi) computed for storing
 *   r11 = running integer accumulator while scanning a literal
 *   rax = scratch / return value
 * ==========================================================================*/
    .section .text

    .globl asm_lex
    .type  asm_lex, @function
asm_lex:
    mov    rax, [rsi]               /* rax = *pos                          */
    lea    rcx, [rdi + rax]         /* rcx = src + *pos                    */

/* ---------- skip inter-token whitespace ---------- */
.skip_ws:
    movzx  r8, byte ptr [rcx]
    cmp    r8, ' '
    je     .skip_ws_inc
    cmp    r8, ASCII_NL             /* \n                                 */
    je     .skip_ws_inc
    cmp    r8, ASCII_CR             /* \r                                 */
    je     .skip_ws_inc
    cmp    r8, 9                    /* \t                                 */
    je     .skip_ws_inc
    jmp    .classify
.skip_ws_inc:
    inc    rcx
    jmp    .skip_ws

/* ---------- classify the first significant character ---------- */
.classify:
    movzx  r8, byte ptr [rcx]
    test   r8, r8
    jz     .eof                     /* NUL -> end of input                 */

    /* string quote?  '"' or '\'' -> scan a literal (whole token incl. quotes) */
    cmp    r8, '"'
    je     .str_token
    cmp    r8, 39                    /* '\''                                 */
    je     .str_token

    /* digit?  '0'..'9' */
    cmp    r8, '0'
    jb     .not_digit
    cmp    r8, '9'
    jbe    .int_token
.not_digit:
    /* letter or underscore -> identifier */
    cmp    r8, '_'
    je     .name_token
    cmp    r8, 'A'
    jb     .not_upper
    cmp    r8, 'Z'
    jbe    .name_token
.not_upper:
    cmp    r8, 'a'
    jb     .op_token
    cmp    r8, 'z'
    jbe    .name_token

    /* anything else that is not whitespace/NUL/alnum -> a single-char
     * operator/punctuation token (value = the character itself).          */
    jmp    .op_token

/* ---------- TOK_INT: scan + accumulate a decimal literal ---------- */
.int_token:
    mov    r9, rcx                  /* start pointer                       */
    xor    r11d, r11d               /* value = 0                           */
.int_digits:
    movzx  r8, byte ptr [rcx]
    cmp    r8, '0'
    jb     .int_done
    cmp    r8, '9'
    ja     .int_done
    imul   r11, r11, 10             /* value = value * 10                  */
    sub    r8b, '0'                 /* r8 = digit 0..9                     */
    add    r11, r8                  /* value += digit                      */
    inc    rcx
    jmp    .int_digits
.int_done:
    mov    rax, r9
    sub    rax, rdi
    mov    [rdx + LEX_OFF_START],  rax   /* start offset                  */
    mov    rax, rcx
    sub    rax, r9
    mov    [rdx + LEX_OFF_LENGTH], rax   /* byte length                   */
    mov    qword ptr [rdx + LEX_OFF_TYPE], TOK_INT
    mov    [rdx + LEX_OFF_VALUE],  r11    /* parsed value                 */
    jmp    .finish

/* ---------- TOK_NAME: scan [A-Za-z0-9_] ---------- */
.name_token:
    mov    r9, rcx
.name_chars:
    movzx  r8, byte ptr [rcx]
    cmp    r8, '0'
    jb     .name_done
    cmp    r8, '9'
    jbe    .name_ok
    cmp    r8, 'A'
    jb     .name_done
    cmp    r8, 'Z'
    jbe    .name_ok
    cmp    r8, '_'
    je     .name_ok
    cmp    r8, 'a'
    jb     .name_done
    cmp    r8, 'z'
    jbe    .name_ok
    jmp    .name_done
.name_ok:
    inc    rcx
    jmp    .name_chars
.name_done:
    mov    rax, r9
    sub    rax, rdi
    mov    [rdx + LEX_OFF_START],  rax
    mov    rax, rcx
    sub    rax, r9
    mov    [rdx + LEX_OFF_LENGTH], rax
    mov    qword ptr [rdx + LEX_OFF_TYPE], TOK_NAME
    mov    qword ptr [rdx + LEX_OFF_VALUE], 0
    jmp    .finish

/* ---------- TOK_STR: scan a string literal between matching quotes --------
 *   The token slice includes the surrounding quotes (start at the open quote,
 *   length = total span). The compiler derives the inner content as
 *   src[start+1 .. start+length-2]. No escape processing yet (simple quotes);
 *   scanning stops at the matching close quote or end-of-input.             */
.str_token:
    mov    r9, rcx                   /* start at the open quote             */
    mov    r10, r8                   /* remember the quote char (r8)         */
    inc    rcx                       /* move past the opening quote          */
.str_scan:
    movzx  r8, byte ptr [rcx]
    test   r8, r8
    jz     .str_scan_done            /* hit NUL -> close on end-of-input     */
    cmp    r8, r10
    je     .str_scan_close
    inc    rcx
    jmp    .str_scan
.str_scan_close:
    inc    rcx                       /* include the closing quote in the slice*/
.str_scan_done:
    mov    rax, r9
    sub    rax, rdi
    mov    [rdx + LEX_OFF_START],  rax
    mov    rax, rcx
    sub    rax, r9
    mov    [rdx + LEX_OFF_LENGTH], rax
    mov    qword ptr [rdx + LEX_OFF_TYPE], TOK_STR
    mov    qword ptr [rdx + LEX_OFF_VALUE], 0
    jmp    .finish

/* ---------- TOK_OP: an operator/punctuation token ------------------------
 *   Handles single-char ops ('=', '(', '+', '-', '<', '>', ...) and the
 *   two-char comparison ops '==' and '!='. Two-char ops are reported with a
 *   synthetic value code (200, 201) so a single byte value field can tell
 *   them apart; one-char ops keep their ASCII code as the value.           */
.op_token:
    mov    r9, rcx                   /* token start                          */
    xor    r11d, r11d
    inc    r11                       /* op_len = 1 (default)                 */
    mov    r10, r8                   /* value = the char (default)           */
    cmp    r8, '='
    jne    .optk_ne
    cmp    byte ptr [rcx + 1], '='
    jne    .optk_emit
    mov    r11, 2                    /* '==' spans two bytes                 */
    mov    r10, 200                  /* synthetic '==' code                  */
    jmp    .optk_emit
.optk_ne:
    cmp    r8, '!'
    jne    .optk_emit
    cmp    byte ptr [rcx + 1], '='
    jne    .optk_emit
    mov    r11, 2                    /* '!=' spans two bytes                 */
    mov    r10, 201                  /* synthetic '!=' code                  */
.optk_emit:
    add    rcx, r11                  /* consume the operator bytes           */
    mov    rax, r9
    sub    rax, rdi
    mov    [rdx + LEX_OFF_START],  rax
    mov    [rdx + LEX_OFF_LENGTH], r11
    mov    qword ptr [rdx + LEX_OFF_TYPE], TOK_OP
    mov    [rdx + LEX_OFF_VALUE],  r10
    jmp    .finish

/* ---------- TOK_EOF: no more input ---------- */
.eof:
    mov    qword ptr [rdx + LEX_OFF_TYPE],  TOK_EOF
    mov    qword ptr [rdx + LEX_OFF_START], 0
    mov    qword ptr [rdx + LEX_OFF_LENGTH],0
    mov    qword ptr [rdx + LEX_OFF_VALUE], 0
    jmp    .finish_advance

/* ---------- common tail: commit the new offset and return ---------- */
.finish:
    mov    rax, rcx
    sub    rax, rdi                 /* new offset = cursor - src           */
    mov    [rsi], rax               /* store it back into *pos             */
    xor    eax, eax                 /* return 0 = a token was produced     */
    ret
.finish_advance:
    mov    rax, rcx
    sub    rax, rdi
    mov    [rsi], rax
    mov    eax, 1                   /* return 1 = end-of-input reached     */
    ret
    .size asm_lex, . - asm_lex

/* Keep the heap page non-executable. */
    .section .note.GNU-stack,"",@progbits
