gobuild= ../../go-build.sh

.PHONEY: all
all: hello.mac hello.linux

hello.mac: *.go $(gobuild) Makefile
	GOOS=darwin GOARCH=amd64 $(gobuild) -o $@

hello.linux: *.go $(gobuild) Makefile
	GOOS=linux GOARCH=amd64 $(gobuild) -o $@

.PHONEY: test
# test on a non-linux host machine
test: hello.linux
	docker run --rm -v `pwd`:/mnt/ -w /mnt busybox ./$<

.PHONEY: test-on-linux
# test on a linux host machine
test-on-linux: hello.linux
	./$<

# build for the host machine as the target
hello.bin: *.go $(gobuild) Makefile
	$(gobuild) -o $@

.PHONEY: clean
clean:
	rm -rf ./hello.* /tmp/go-build-bash
