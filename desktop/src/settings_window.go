package main

import (
	"runtime"

	"github.com/wailsapp/wails/v3/pkg/application"
)

const (
	settingsWindowWidth  = 400
	settingsWindowHeight = 540
	// Windows DWM frameless decorations shrink the WebView2 client area.
	settingsWindowWindowsExtraHeight = 32
	settingsWindowMinWidth           = 320
	settingsWindowMinHeight          = 420
	settingsWorkAreaHeightPercent    = 88
)

func settingsWindowChromeExtra() int {
	if runtime.GOOS == "windows" {
		return settingsWindowWindowsExtraHeight
	}
	return 0
}

func settingsWindowOuterHeight() int {
	return settingsWindowHeight + settingsWindowChromeExtra()
}

// settingsWindowSizeForWorkArea picks a window size that fits the screen
// work area (taskbar excluded). Heights are DIP, matching Wails Bounds.
// Small / high-DPI logical desktops cap height so the tray popover is not
// clipped; the settings card scrolls while action buttons stay visible.
func settingsWindowSizeForWorkArea(workW, workH, extraH int) (width, height int) {
	if workW < 1 {
		workW = settingsWindowWidth
	}
	if workH < 1 {
		workH = settingsWindowOuterHeight()
	}
	wantH := settingsWindowHeight + extraH
	maxH := workH * settingsWorkAreaHeightPercent / 100
	if maxH < 1 {
		maxH = workH
	}
	minH := settingsWindowMinHeight
	if minH > maxH {
		minH = maxH
	}
	height = wantH
	if height > maxH {
		height = maxH
	}
	if height < minH {
		height = minH
	}

	width = settingsWindowWidth
	maxW := workW - 24
	if maxW < settingsWindowMinWidth {
		maxW = workW
	}
	if maxW < 1 {
		maxW = settingsWindowWidth
	}
	if width > maxW {
		width = maxW
	}
	if width < 1 {
		width = settingsWindowMinWidth
	}
	return width, height
}

func applySettingsWindowSize(app *application.App, win *application.WebviewWindow) {
	if app == nil || win == nil {
		return
	}
	screen := app.Screen.GetPrimary()
	if current, err := win.GetScreen(); err == nil && current != nil {
		screen = current
	}
	workW, workH := 0, 0
	if screen != nil {
		workW = screen.WorkArea.Width
		workH = screen.WorkArea.Height
		if workW < 1 {
			workW = screen.Size.Width
		}
		if workH < 1 {
			workH = screen.Size.Height
		}
	}
	w, h := settingsWindowSizeForWorkArea(workW, workH, settingsWindowChromeExtra())
	win.SetMinSize(min(w, settingsWindowMinWidth), min(h, settingsWindowMinHeight))
	win.SetSize(w, h)
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
