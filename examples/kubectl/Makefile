gobuild= ../../go-build.sh

.PHONEY: all
all: kubectl.mac kubectl.linux

vendor: go.mod
	go mod vendor

kubectl.mac: *.go $(gobuild) Makefile vendor
	GOOS=darwin GOARCH=amd64 $(gobuild) -o $@

kubectl.linux: *.go $(gobuild) Makefile vendor
	GOOS=linux GOARCH=amd64 $(gobuild) -o $@

.PHONEY: test
# test on a non-linux host machine
test: kubectl.linux
	docker run --rm -v `pwd`:/mnt/ -w /mnt busybox ./$< --help

.PHONEY: test-on-linux
# test on a linux host machine
test-on-linux: kubectl.linux
	./$< --help

# build for the host machine as the target
kubectl.bin: *.go $(gobuild) Makefile
	$(gobuild) -o $@

.PHONEY: clean
clean:
	rm -rf ./kubectl.* /tmp/go-build-bash ./vendor
