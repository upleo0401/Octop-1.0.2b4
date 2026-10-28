//go:build windows

package main

import "testing"

func acquireTestInstance(t *testing.T, onActivate func()) (func(), bool) {
	t.Helper()
	name := "Local\\OctopDesktopTest-" + t.Name()
	return acquireNamedSingleInstance(name, name+"-ev", onActivate)
}
