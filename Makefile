.PHONEY: all
all:
	make -C examples/hello all

.PHONEY: test-on-linux
test-on-linux:
	make -C examples/hello test-on-linux

.PHONEY: clean
clean:
	make -C examples/hello clean
