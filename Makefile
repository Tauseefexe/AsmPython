# AsmPython -- top-level build driver.
#
#   make           -> build the Phase-1 assembly core
#   make test      -> build core + build & run the validation test
#   make clean     -> remove all build artifacts
#   make disasm    -> disassemble the assembly core (sanity check)

SUBDIRS := src test

all:
	$(MAKE) -C src

test:
	$(MAKE) -C src
	$(MAKE) -C test run

disasm: all
	objdump -d -Mintel build/pyobject.o

clean:
	$(MAKE) -C src clean
	$(MAKE) -C test clean

.PHONY: all test disasm clean
