# go-build-bash

A bash script that emulates `go build`.

The purpose of this project is to help go users learn how `go build` works.

# Prerequisite

## Host machine
* Bash 5.1 or later
* go version 1.20
* OS:MacOS or Linux
* (On MacOS) `brew install bash findutils gnu-sed`
* CPU:x86-64

## Target machine
* Linux or MacOS of x86-64

4 combinations of cross OS building (Host: darwin,linux) => (Target: darwin,linux) are supported.

# Usage

```
$ GOOS=linux GOARCH=amd64 ./go-build.sh -o hello
$ docker run --rm -v `pwd`:/mnt/ -w /mnt busybox ./hello

hello world (go1.20.4)
```

# TODO
* [ ] Refactor code
* [ ] Support vendor directory
* [ ] Support Apple silicon
* [ ] Debug option

# License
MIT

# Author
@DQNEO
