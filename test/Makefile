# AsmPython -- validation tests (Phases 1 & 2).
#
#   make        -> build + run every test against the assembly core
#   make run    -> (same)
#   make clean  -> remove built test binaries

BUILDDIR := ../build
CC       ?= gcc
CFLAGS   ?= -O2 -g -Wall -Wextra -std=c11
LDFLAGS  := $(BUILDDIR)/libasmpython.a

BINS := $(BUILDDIR)/test_pyobject $(BUILDDIR)/test_refcount $(BUILDDIR)/test_pysize \
        $(BUILDDIR)/test_intobj $(BUILDDIR)/test_intarith $(BUILDDIR)/test_io \
        $(BUILDDIR)/test_lexer $(BUILDDIR)/test_compile $(BUILDDIR)/test_strobj \
        $(BUILDDIR)/test_objectproto $(BUILDDIR)/test_vm

all: run

$(BUILDDIR)/test_pyobject: test_pyobject.c $(BUILDDIR)/libasmpython.a
	$(CC) $(CFLAGS) -o $@ test_pyobject.c $(LDFLAGS)

$(BUILDDIR)/test_refcount: test_refcount.c $(BUILDDIR)/libasmpython.a
	$(CC) $(CFLAGS) -o $@ test_refcount.c $(LDFLAGS)

$(BUILDDIR)/test_pysize: test_pysize.c $(BUILDDIR)/libasmpython.a
	$(CC) $(CFLAGS) -o $@ test_pysize.c $(LDFLAGS)

$(BUILDDIR)/test_intobj: test_intobj.c $(BUILDDIR)/libasmpython.a
	$(CC) $(CFLAGS) -o $@ test_intobj.c $(LDFLAGS)

$(BUILDDIR)/test_intarith: test_intarith.c $(BUILDDIR)/libasmpython.a
	$(CC) $(CFLAGS) -o $@ test_intarith.c $(LDFLAGS)

$(BUILDDIR)/test_io: test_io.c $(BUILDDIR)/libasmpython.a
	$(CC) $(CFLAGS) -o $@ test_io.c $(LDFLAGS)

$(BUILDDIR)/test_lexer: test_lexer.c $(BUILDDIR)/libasmpython.a
	$(CC) $(CFLAGS) -o $@ test_lexer.c $(LDFLAGS)

$(BUILDDIR)/test_compile: test_compile.c $(BUILDDIR)/libasmpython.a
	$(CC) $(CFLAGS) -o $@ test_compile.c $(LDFLAGS)

$(BUILDDIR)/test_strobj: test_strobj.c $(BUILDDIR)/libasmpython.a
	$(CC) $(CFLAGS) -o $@ test_strobj.c $(LDFLAGS)

$(BUILDDIR)/test_objectproto: test_objectproto.c $(BUILDDIR)/libasmpython.a
	$(CC) $(CFLAGS) -o $@ test_objectproto.c $(LDFLAGS)

$(BUILDDIR)/test_vm: test_vm.c $(BUILDDIR)/libasmpython.a
	$(CC) $(CFLAGS) -o $@ test_vm.c $(LDFLAGS)

run: $(BINS)
	@for t in $(BINS); do echo "===== $$(basename $$t) ====="; ./$$t || exit 1; echo; done

clean:
	rm -f $(BINS)

.PHONY: all run clean
