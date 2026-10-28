//go:build production && !darwin && !windows

package main

import _ "embed"

// Linux production builds embed their matching portable runtime.
//
//go:embed all:bundled/portable.zip
var embeddedPortable []byte
