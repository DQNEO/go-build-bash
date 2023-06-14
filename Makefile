.PHONEY: test-hello-mac
test-hello-mac:
	make -C examples/hello test-on-mac

.PHONEY: test-hello-linux
test-hello-linux:
	make -C examples/hello test-on-linux

.PHOENY: clean
clean:
	rm -rf /tmp/go-build-bash
