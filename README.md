# AsmPython

An exact, from-scratch clone of the CPython interpreter built in modern
x86-64 assembly (Linux System V AMD64 ABI), driven in micro-steps.

## Layout

```
src/pyobject.S     Phases 1-3 -- PyObject core: mmap arena + object factory +
                              size-class free lists (allocate AND reclaim)
src/refcount.S     Phase 2 -- reference counting: asm_incref / asm_decref +
                              the built-in "object" type (dealloc dispatch)
src/intobj.S       Phases 4-5 -- the "int" type + CPython small-int cache
                              (-5..256 singletons) + int add/sub arithmetic
src/io.S           Phase 6   -- output layer: int->decimal + stdout writes
src/vm.S           Phase 6   -- the bytecode virtual machine (dispatch loop,
                              value/global stacks) + stdout print helpers
src/lexer.S        Phase 7   -- lexer: Python source text -> token stream
src/compile.S      Phase 8   -- compiler: token stream -> VM bytecode (source
                              text is now compiled AND run by the VM)
src/strobj.S       Phase 9   -- str type (compact byte-strings) + literals,
                              so print("hello") works
src/objectproto.S  Phase 10  -- None/True/False singletons + ==,!=,<,>
                              comparisons producing real bools
include/           Public C header (mirror of the assembly layouts; test-only)
test/              Validation harnesses for each phase
Makefile           Top-level build driver
```

## Build & test

```
make          # assemble the core (build/libasmpython.a)
make test     # assemble + build + run every validation harness
make disasm   # disassemble the core to verify the emitted machine code
```

Requires only the standard GNU toolchain: `as`, `ar`, `cc`.

## Phase roadmap (micro-steps, each validated before the next)

- Phase 1: PyObject layout + primitive allocation/initialisation (arena).
- Phase 2: INCREF / DECREF + free-list reuse + built-in "object" type.
- Phase 3: size-class allocator -- typed objects of any footprint are
  allocated *and* reclaimed via per-size free lists (`basic_size`).
- Phase 4: the "int" type + CPython's small-int cache (-5..256 immortal
  singletons); dealloc is immortal-aware.
- Phase 5: int add / subtract arithmetic -- results route back through the
  cache, so 2+3 is literally the 5 singleton.
- Phase 6: the bytecode virtual machine -- a CPython-style dispatch loop over
  an instruction stream: LOAD_CONST/GLOBAL, STORE_GLOBAL, BINARY_ADD/SUB,
  PRINT, RETURN_VALUE, plus stdout printing helpers.
- Phase 7: a text lexer -- tokenises Python source into a stream the parser
  can consume.
- Phase 8: a recursive-descent compiler -- lowers a real subset of Python
  source (assignments, +/- expressions, parens, print) into VM bytecode +
  constant pool, closing the loop: source text now compiles AND runs.
- Phase 9: str type + string literals -- print("hello") now works; the lexer
  and compiler handle quoted text.
- Phase 10: None/True/False immortal singletons and == / != / < / >
  comparisons (single VMOP_COMPARE), with bool and None printing.
- Phase 11: (next) more types (list / dict), richer statements and
  operators, then functions/frames and control flow.
