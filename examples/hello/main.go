package main

import (
	"github.com/DQNEO/go-build-bash/examples/hello/lib"

	"fmt"
	"runtime"
)

func main() {
	hello := Hello()
	world := lib.World()
	fmt.Printf("%s %s (%s)\n", hello, world, runtime.Version())
}
