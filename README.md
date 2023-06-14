# go-build-bash

A bash script that emulates `go build`.

The purpose of this project is to help go users learn how `go build` works.

# Prerequisite

## Host machine
* Bash 5.1 or later
* go version 1.20
* OS:MacOS or Linux
* (On MacOS) `brew install bash findutils gnu-sed coreutils`
* CPU:x86-64

## Target machine
* Linux or MacOS of x86-64

4 combinations of cross compile (Host: darwin,linux) => (Target: darwin,linux) are supported.

# Usage

Build a hello world program

```
$ cd examples/hello
$ GOOS=linux GOARCH=amd64 ../../go-build.sh
$ docker run --rm -v `pwd`:/mnt/ -w /mnt busybox ./hello

hello world
```

Build kubectl

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
