//go:build windows

package main

import "golang.org/x/sys/windows"

func alertError(title, msg string) {
	caption, err := windows.UTF16PtrFromString(title)
	if err != nil {
		return
	}
	text, err := windows.UTF16PtrFromString(msg)
	if err != nil {
		return
	}
	_, _ = windows.MessageBox(0, text, caption, windows.MB_OK|windows.MB_ICONERROR)
}
