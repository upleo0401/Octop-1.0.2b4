package main

import "testing"

func TestSettingsWindowSizeFitsFHD(t *testing.T) {
	w, h := settingsWindowSizeForWorkArea(1920, 1040, 32)
	if w != 400 {
		t.Fatalf("width=%d", w)
	}
	if h != settingsWindowHeight+32 {
		t.Fatalf("height=%d want %d", h, settingsWindowHeight+32)
	}
}

func TestSettingsWindowSizeCapsToSmallLogicalDesktop(t *testing.T) {
	// 1280x720 at 150% ≈ 853x480 logical; work area even shorter.
	_, h := settingsWindowSizeForWorkArea(853, 440, 32)
	max := 440 * settingsWorkAreaHeightPercent / 100
	if h > max {
		t.Fatalf("height %d exceeds %d%% of work area (%d)", h, settingsWorkAreaHeightPercent, max)
	}
	if h < 360 {
		t.Fatalf("height %d is too small to show actions", h)
	}
}

func TestSettingsWindowSizeNeverExceedsTinyWorkArea(t *testing.T) {
	w, h := settingsWindowSizeForWorkArea(320, 400, 32)
	if w > 320 {
		t.Fatalf("width %d wider than work area", w)
	}
	if h > 400 {
		t.Fatalf("height %d taller than work area", h)
	}
}

func TestSettingsWindowConstants(t *testing.T) {
	if settingsWindowWidth != 400 {
		t.Fatalf("width %d", settingsWindowWidth)
	}
	if settingsWindowHeight < 500 || settingsWindowHeight > 600 {
		t.Fatalf("preferred height %d", settingsWindowHeight)
	}
	if settingsWindowWindowsExtraHeight < 24 {
		t.Fatal("Windows extra height too small")
	}
	if settingsWindowOuterHeight() < settingsWindowHeight {
		t.Fatal("outer height must include chrome extra")
	}
}
