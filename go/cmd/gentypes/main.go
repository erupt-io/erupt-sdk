// Command gentypes syncs the erupt schemas into the package and generates types.go from them.
//
//	go run ./cmd/gentypes <erupt repo>/schema          # copy schemas, regenerate types.go
//	go run ./cmd/gentypes -check <erupt repo>/schema   # fail when anything is out of date (CI)
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
	check := flag.Bool("check", false, "report stale files instead of writing them")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: go run ./cmd/gentypes [-check] <erupt repo>/schema")
		flag.PrintDefaults()
	}
	flag.Parse()
	if flag.NArg() != 1 {
		flag.Usage()
		os.Exit(2)
	}
	expected := map[string][]byte{}
	for _, name := range gentypes.Files {
		data, err := os.ReadFile(filepath.Join(flag.Arg(0), name))
		if err != nil {
			fail(err)
		}
		expected[name] = data
	}
	types, err := gentypes.Generate(expected[gentypes.Files[0]])
	if err != nil {
		fail(err)
	}
	expected["types.go"] = types
	stale := false
	for _, name := range append(append([]string{}, gentypes.Files...), "types.go") {
		current, err := os.ReadFile(name)
		if err == nil && bytes.Equal(current, expected[name]) {
			continue
		}
		stale = true
		if *check {
			fmt.Println("stale: go/" + name)
			continue
		}
		if err := os.WriteFile(name, expected[name], 0o644); err != nil {
			fail(err)
		}
		fmt.Println("wrote go/" + name)
	}
	if *check && stale {
		os.Exit(1)
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
