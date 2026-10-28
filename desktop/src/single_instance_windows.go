//go:build windows

package main

import (
	"log"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	octopDesktopMutex = "Local\\OctopDesktopMutex"
	octopDesktopEvent = "Local\\OctopDesktopActivate"
	octopMainTitle    = "AimiOct"
)

var (
	moduser32                    = windows.NewLazySystemDLL("user32.dll")
	procFindWindowW              = moduser32.NewProc("FindWindowW")
	procShowWindow               = moduser32.NewProc("ShowWindow")
	procSetForegroundWindow      = moduser32.NewProc("SetForegroundWindow")
	procAllowSetForegroundWindow = moduser32.NewProc("AllowSetForegroundWindow")
)

const asfwAny = ^uintptr(0)

// acquireSingleInstance returns ok=false when another desktop process holds
// the mutex. The second process asks the first to show its window, then exits.
func acquireSingleInstance(onActivate func()) (func(), bool) {
	return acquireNamedSingleInstance(octopDesktopMutex, octopDesktopEvent, onActivate)
}

func acquireNamedSingleInstance(mutexName, eventName string, onActivate func()) (func(), bool) {
	mName, err := windows.UTF16PtrFromString(mutexName)
	if err != nil {
		log.Printf("single-instance mutex name: %v", err)
		return func() {}, true
	}
	mutex, err := windows.CreateMutex(nil, false, mName)
	if mutex == 0 {
		log.Printf("single-instance mutex: %v", err)
		return func() {}, true
	}
	if err == windows.ERROR_ALREADY_EXISTS {
		notifyExistingInstance(eventName)
		_ = windows.CloseHandle(mutex)
		return nil, false
	}

	eName, err := windows.UTF16PtrFromString(eventName)
	if err != nil {
		log.Printf("single-instance event name: %v", err)
		return func() { _ = windows.CloseHandle(mutex) }, true
	}
	event, err := windows.CreateEvent(nil, 0, 0, eName)
	if event == 0 {
		log.Printf("single-instance event: %v", err)
		return func() { _ = windows.CloseHandle(mutex) }, true
	}

	stop := make(chan struct{})
	go waitForActivate(event, stop, onActivate)
	return func() {
		close(stop)
		_ = windows.CloseHandle(event)
		_ = windows.CloseHandle(mutex)
	}, true
}

func waitForActivate(event windows.Handle, stop <-chan struct{}, onActivate func()) {
	for {
		status, err := windows.WaitForSingleObject(event, 200)
		select {
		case <-stop:
			return
		default:
		}
		if err != nil {
			continue
		}
		if status == windows.WAIT_OBJECT_0 && onActivate != nil {
			onActivate()
		}
	}
}

func notifyExistingInstance(eventName string) {
	_, _, _ = procAllowSetForegroundWindow.Call(asfwAny)
	restoreExistingMainWindow()
	name, err := windows.UTF16PtrFromString(eventName)
	if err != nil {
		return
	}
	var last error
	for range 20 {
		event, err := windows.OpenEvent(windows.EVENT_MODIFY_STATE, false, name)
		if err == nil {
			_ = windows.SetEvent(event)
			_ = windows.CloseHandle(event)
			return
		}
		last = err
		time.Sleep(50 * time.Millisecond)
	}
	if last != nil {
		log.Printf("notify existing Octop desktop: %v", last)
	}
}

func restoreExistingMainWindow() {
	title, err := windows.UTF16PtrFromString(octopMainTitle)
	if err != nil {
		return
	}
	hwnd, _, _ := procFindWindowW.Call(0, uintptr(unsafe.Pointer(title)))
	if hwnd == 0 {
		return
	}
	_, _, _ = procShowWindow.Call(hwnd, windows.SW_RESTORE)
	_, _, _ = procShowWindow.Call(hwnd, windows.SW_SHOW)
	_, _, _ = procSetForegroundWindow.Call(hwnd)
}
