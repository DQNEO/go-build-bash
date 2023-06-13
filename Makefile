.PHONEY: all
all:
	make -C examples/hello all

.PHONEY: test-on-mac
test-on-mac:
	make -C examples/hello $@

.PHONEY: test-on-linux
test-on-linux:
	make -C examples/hello $@

.PHONEY: clean
clean:
	make -C examples/hello clean
