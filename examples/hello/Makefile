gobuild= ../../go-build.sh

.PHONEY: all
all: hello.mac hello.linux

hello.mac: *.go $(gobuild) Makefile
	GOOS=darwin GOARCH=amd64 $(gobuild) -o $@

hello.linux: *.go $(gobuild) Makefile
	GOOS=linux GOARCH=amd64 $(gobuild) -o $@

.PHONEY: test-on-mac
# test both binaries
test-on-mac: hello.mac hello.linux
	./hello.mac
	docker run --rm -v `pwd`:/mnt/ -w /mnt busybox ./hello.linux

.PHONEY: test-on-linux
# test on a linux host machine
test-on-linux: hello.mac hello.linux
	./hello.linux
	file ./hello.mac

# build for the host machine as the target
hello.bin: *.go $(gobuild) Makefile
	$(gobuild) -o $@

.PHONEY: clean
clean:
	rm -rf ./hello.* /tmp/go-build-bash
