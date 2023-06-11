.PHONEY: all
all: hello.mac hello.linux

hello.mac: *.go go-build.sh Makefile
	GOOS=darwin GOARCH=amd64 ./go-build.sh -o $@

hello.linux: *.go go-build.sh Makefile
	GOOS=linux GOARCH=amd64 ./go-build.sh -o $@

.PHONEY: test
# test on a non-linux host machine
test: hello.linux
	docker run --rm -v `pwd`:/mnt/ -w /mnt busybox ./$<

.PHONEY: test-on-linux
# test on a linux host machine
test-on-linux: hello.linux
	./$<

# build for the host machine as the target
hello: *.go go-build.sh Makefile
	./go-build.sh -o $@

.PHONEY: clean
clean:
	rm -rf ./hello ./hello.* /tmp/go-build-bash ./go-build-bash

