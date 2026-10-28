package main

import (
	"log"
	"os"
	"path/filepath"
	"time"
)

func initDesktopLog() {
	if err := os.MkdirAll(octopHome(), 0o755); err != nil {
		return
	}
	path := filepath.Join(octopHome(), "desktop.log")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	// GUI subsystem builds have no stderr; writing it can fail the first log
	// and look like the process never started.
	log.SetOutput(f)
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	log.Printf("desktop start %s", time.Now().Format(time.RFC3339))
}
