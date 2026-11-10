// Command gentypes generates types.go from the erupt annotation schema.
//
//	go run ./cmd/gentypes <erupt repo>/schema          # regenerate types.go
//	go run ./cmd/gentypes -check <erupt repo>/schema   # fail when it is out of date (CI)
//
// Run it from the module root (the go/ directory).
package main

import (
	"bytes"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/erupt-io/erupt-sdk/go/internal/gentypes"
)

func main() {
	check := flag.Bool("check", false, "report a stale types.go instead of writing it")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: go run ./cmd/gentypes [-check] <erupt repo>/schema")
		flag.PrintDefaults()
	}
	flag.Parse()
	if flag.NArg() != 1 {
		flag.Usage()
		os.Exit(2)
	}
	schema, err := os.ReadFile(filepath.Join(flag.Arg(0), gentypes.Schema))
	if err != nil {
		fail(err)
	}
	expected, err := gentypes.Generate(schema)
	if err != nil {
		fail(err)
	}
	if current, err := os.ReadFile("types.go"); err == nil && bytes.Equal(current, expected) {
		return
	}
	if *check {
		fmt.Println("stale: go/types.go")
		os.Exit(1)
	}
	if err := os.WriteFile("types.go", expected, 0o644); err != nil {
		fail(err)
	}
	fmt.Println("wrote go/types.go")
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
