//go:build !windows

package main

import (
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/sys/unix"
)

const activatePayload = "show\n"

func acquireSingleInstance(onActivate func()) (func(), bool) {
	root := octopHome()
	if err := os.MkdirAll(root, 0o755); err != nil {
		log.Printf("single-instance home: %v", err)
		return func() {}, true
	}
	return acquirePathSingleInstance(
		filepath.Join(root, "desktop.lock"),
		filepath.Join(root, "desktop.sock"),
		onActivate,
	)
}

func acquirePathSingleInstance(lockPath, sockPath string, onActivate func()) (func(), bool) {
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		log.Printf("single-instance lock: %v", err)
		return func() {}, true
	}
	if err := unix.Flock(int(f.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		_ = f.Close()
		notifyExistingUnix(sockPath)
		return nil, false
	}
	_ = os.Remove(sockPath)
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		log.Printf("single-instance socket: %v", err)
		_ = unix.Flock(int(f.Fd()), unix.LOCK_UN)
		_ = f.Close()
		return func() {}, true
	}
	done := make(chan struct{})
	go acceptActivate(ln, done, onActivate)
	return func() {
		_ = ln.Close()
		<-done
		_ = os.Remove(sockPath)
		_ = unix.Flock(int(f.Fd()), unix.LOCK_UN)
		_ = f.Close()
	}, true
}

func acceptActivate(ln net.Listener, done chan struct{}, onActivate func()) {
	defer close(done)
	for {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		_, _ = io.Copy(io.Discard, conn)
		_ = conn.Close()
		if onActivate != nil {
			onActivate()
		}
	}
}

func notifyExistingUnix(sockPath string) {
	conn, err := net.DialTimeout("unix", sockPath, time.Second)
	if err != nil {
		log.Printf("notify existing Octop desktop: %v", err)
		return
	}
	_, _ = io.WriteString(conn, activatePayload)
	_ = conn.Close()
}
