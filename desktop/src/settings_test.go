package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestWebviewUserDataDirIsUnderOctopHome(t *testing.T) {
	temp := t.TempDir()
	t.Setenv("OCTOP_HOME", temp)
	got := webviewUserDataDir()
	if got != filepath.Join(temp, "desktop-webview") {
		t.Fatalf("got %q", got)
	}
}

func TestLoadSettingsMigratesLegacyPreventSleepMac(t *testing.T) {
	temp := t.TempDir()
	t.Setenv("OCTOP_HOME", temp)
	if err := os.WriteFile(
		filepath.Join(temp, "desktop-settings.json"),
		[]byte(`{"preventSleepMac":true}`),
		0o644,
	); err != nil {
		t.Fatal(err)
	}

	if !loadSettings().PreventSleep {
		t.Fatal("legacy preventSleepMac should migrate to preventSleep")
	}
}

func TestNormalizeServerURL(t *testing.T) {
	got, err := normalizeServerURL(" https://octop.example.com/ ")
	if err != nil {
		t.Fatal(err)
	}
	if got != "https://octop.example.com" {
		t.Fatalf("got %q", got)
	}
	if _, err := normalizeServerURL("not-a-url"); err == nil {
		t.Fatal("expected error")
	}
	empty, err := normalizeServerURL("  ")
	if err != nil || empty != "" {
		t.Fatalf("empty: %q %v", empty, err)
	}
}

func TestEffectiveRemoteURLPrefersEnv(t *testing.T) {
	t.Setenv("OCTOP_DESKTOP_URL", "https://company.example:8443/")
	if got := effectiveRemoteURL(Settings{ServerURL: "http://127.0.0.1:8088"}); got != "https://company.example:8443" {
		t.Fatalf("got %q", got)
	}
}

func TestFillBundledServerURLWhenEmpty(t *testing.T) {
	if bundledDefaultServerURL == "" {
		t.Skip("no bundled company server")
	}
	s := fillBundledServerURL(Settings{})
	if s.ServerURL != "http://192.168.3.61:8088" {
		t.Fatalf("serverUrl=%q", s.ServerURL)
	}
	kept := fillBundledServerURL(Settings{ServerURL: "http://other.example:9"})
	if kept.ServerURL != "http://other.example:9" {
		t.Fatalf("kept=%q", kept.ServerURL)
	}
}

func TestLoadSettingsFillsBundledServerURL(t *testing.T) {
	if bundledDefaultServerURL == "" {
		t.Skip("no bundled company server")
	}
	temp := t.TempDir()
	t.Setenv("OCTOP_HOME", temp)
	t.Setenv("OCTOP_DESKTOP_URL", "")
	if err := os.WriteFile(
		filepath.Join(temp, "desktop-settings.json"),
		[]byte(`{"locale":"zh"}`),
		0o644,
	); err != nil {
		t.Fatal(err)
	}
	s := loadSettings()
	if s.ServerURL != "http://192.168.3.61:8088" {
		t.Fatalf("serverUrl=%q", s.ServerURL)
	}
}

func TestAllowLocalRuntimeDisabledWhenBundled(t *testing.T) {
	if bundledDefaultServerURL != "" && allowLocalRuntime() {
		t.Fatal("thin client must not start a local wizard")
	}
}

func TestLoadSettingsIgnoresPersistedServerURL(t *testing.T) {
	temp := t.TempDir()
	t.Setenv("OCTOP_HOME", temp)
	t.Setenv("OCTOP_DESKTOP_URL", "")
	if err := os.WriteFile(
		filepath.Join(temp, "desktop-settings.json"),
		[]byte(`{"locale":"zh","serverUrl":"http://192.168.3.61:8088"}`),
		0o644,
	); err != nil {
		t.Fatal(err)
	}
	s := loadSettings()
	if s.ServerURL != "" {
		t.Fatalf("serverUrl=%q", s.ServerURL)
	}
	if s.RemoteURLLocked {
		t.Fatal("should not lock without env")
	}
}
