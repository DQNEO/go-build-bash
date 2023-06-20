# go-build-bash

A bash script that emulates `go build`.

The goal of this project is to help Go users understand what to do to build a package.

Some advantages of `go-build-bash` over the official `go build` include:

* The script is written in bash, making it easier to understand for those unfamiliar with Go.
* The build log is carefully designed, providing a clear view of the process. You can see [an example log of building "hello world" program here](https://gist.github.com/DQNEO/7b0710b08baa4eb2fc6fb8bde8c432e1).


It can build large modules like `kubectl` , `uber-go/zap`, `spf13/cobra`, `golang/protobuf` etc.

# Prerequisite

## Host machine
* Bash 5.1 or later
* go version 1.20
* OS:MacOS or Linux
* (On MacOS) `brew install bash findutils gnu-sed coreutils`
* CPU:x86-64

# Cross compilation supported

4 combinations of cross OS compilation are supported:
* darwin => darwin
* darwin => linux
* linux => darwin
* linux => linux 

# Usage

Build a "hello world" program:

```
$ cd examples/hello
$ GOOS=linux GOARCH=amd64 ../../go-build.sh
$ docker run --rm -v `pwd`:/mnt/ -w /mnt busybox ./hello

hello world
```

Build kubectl:

```
$ cd examples/kubectl
$ GOOS=linux GOARCH=amd64 ../../go-build.sh
$ docker run --rm -v `pwd`:/mnt/ -w /mnt busybox ./kubectl version
```

# TODO
* [ ] Support Apple silicon
* [ ] Debug features

# License
MIT

# Author
@DQNEO
