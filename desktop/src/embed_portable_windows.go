//go:build production && windows

package main

// Windows installers ship AimiOct-windows-amd64.zip beside AimiOct.exe (NSIS).
// go:embed cannot reliably include bundled/portable.zip because it is gitignored.
var embeddedPortable []byte
