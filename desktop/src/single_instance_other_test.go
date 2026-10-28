//go:build !windows

package main

import "testing"

func acquireTestInstance(t *testing.T, onActivate func()) (func(), bool) {
	t.Helper()
	dir := t.TempDir()
	return acquirePathSingleInstance(dir+"/desktop.lock", dir+"/desktop.sock", onActivate)
}
