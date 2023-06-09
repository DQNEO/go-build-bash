package main

import (
	"fmt"
	"runtime"
)

func main() {
	world := w()
	fmt.Printf("hello %s (%s)\n", world, runtime.Version())
}
