# go-build-bash

A bash script that emulates `go build`.

The purpose of this project is to help go users learn how `go build` works.

# Prerequisite

## Host machine
* Bash 5.1 or later
* go version 1.20
* (On MacOS) `brew install findutils gnu-sed`
* OS:MacOS or Linux
* CPU:x86-64

## Target machine
* Linux x86-64 or MacOS

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
