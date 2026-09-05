# AsmPython -- Phase 1 & 2 library.
# Produces build/libasmpython.a from the assembly core.
#
#   make          -> build/libasmpython.a
#   make clean    -> remove the built library

BUILDDIR := ../build
AS       ?= as
ASFLAGS  ?= --64

OBJS := $(BUILDDIR)/pyobject.o $(BUILDDIR)/refcount.o $(BUILDDIR)/intobj.o \
        $(BUILDDIR)/strobj.o $(BUILDDIR)/objectproto.o $(BUILDDIR)/io.o \
        $(BUILDDIR)/vm.o $(BUILDDIR)/lexer.o $(BUILDDIR)/compile.o \
        $(BUILDDIR)/vm.o

all: $(BUILDDIR)/libasmpython.a

$(BUILDDIR)/%.o: %.S
	@mkdir -p $(BUILDDIR)
	$(AS) $(ASFLAGS) -o $@ $<

$(BUILDDIR)/libasmpython.a: $(OBJS)
	ar rcs $@ $^

clean:
	rm -f $(OBJS) $(BUILDDIR)/libasmpython.a

.PHONY: all clean
