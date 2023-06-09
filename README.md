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
* Linux x86-64

# Usage

```
$ ./go-build.sh
$ docker run --rm -v `pwd`:/mnt/ -w /mnt ubuntu ./hello

hello world (go1.20.4)
```

# License
MIT

# Author
@DQNEO
