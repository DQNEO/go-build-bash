package main

import (
	"github.com/DQNEO/go-build-bash/lib"

	"fmt"
	"runtime"
)

func main() {
	world := w()
	n := lib.Sum(30, 12)
	fmt.Printf("hello %s %d (%s)\n", world, n, runtime.Version())
}
