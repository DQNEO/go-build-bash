package main

import (
	"github.com/DQNEO/go-build-bash/examples/hello/lib"

	"fmt"
)

func main() {
	hello := Hello()
	world := lib.World()
	fmt.Printf("%s %s\n", hello, world)
}
