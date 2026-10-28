package main

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
)

type Locale string

const (
	LocaleZH Locale = "zh"
	LocaleEN Locale = "en"
)

// Settings is persisted at ~/.octop/desktop-settings.json
type Settings struct {
	Locale         Locale `json:"locale"`
	Autostart      bool   `json:"autostart"`
	MinimizeToTray bool   `json:"minimizeToTray"`
	PreventSleep   bool   `json:"preventSleep"`
	Port           int    `json:"port,omitempty"`
	ServerURL      string `json:"serverUrl,omitempty"`
	// RemoteURLLocked is true when OCTOP_DESKTOP_URL is set (not persisted).
	RemoteURLLocked bool `json:"remoteUrlLocked,omitempty"`
}

// bundledDefaultServerURL is the company Octop control plane. When set, the
// desktop client is a thin client: it never starts a local first-run wizard.
const bundledDefaultServerURL = ""

func defaultSettings() Settings {
	return Settings{
		Locale:         LocaleZH,
		Autostart:      false,
		MinimizeToTray: true,
		PreventSleep:   false,
		Port:           8088,
		ServerURL:      bundledDefaultServerURL,
	}
}

func allowLocalRuntime() bool {
	return bundledDefaultServerURL == ""
}

func fillBundledServerURL(s Settings) Settings {
	if strings.TrimSpace(s.ServerURL) != "" {
		return s
	}
	if u, err := normalizeServerURL(bundledDefaultServerURL); err == nil && u != "" {
		s.ServerURL = u
	}
	return s
}

func octopHome() string {
	if v := os.Getenv("OCTOP_HOME"); v != "" {
		return v
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ".octop"
	}
	return filepath.Join(home, ".octop")
}

func portableDir() string {
	return filepath.Join(octopHome(), "portable")
}

func settingsPath() string {
	return filepath.Join(octopHome(), "desktop-settings.json")
}

func webviewUserDataDir() string {
	return filepath.Join(octopHome(), "desktop-webview")
}

type settingsStore struct {
	mu  sync.Mutex
	cur Settings
}

func loadSettings() Settings {
	s := defaultSettings()
	data, err := os.ReadFile(settingsPath())
	if err != nil {
		s.RemoteURLLocked = strings.TrimSpace(os.Getenv("OCTOP_DESKTOP_URL")) != ""
		return s
	}
	_ = json.Unmarshal(data, &s)
	var legacy struct {
		PreventSleepMac bool `json:"preventSleepMac"`
	}
	_ = json.Unmarshal(data, &legacy)
	if !s.PreventSleep {
		s.PreventSleep = legacy.PreventSleepMac
	}
	if s.Port == 0 {
		s.Port = 8088
	}
	if s.Locale != LocaleZH {
		s.Locale = LocaleEN
	}
	// Option A: never reconnect to a persisted remote Octop URL.
	s.ServerURL = ""
	s = fillBundledServerURL(s)
	s.RemoteURLLocked = strings.TrimSpace(os.Getenv("OCTOP_DESKTOP_URL")) != ""
	return s
}

func normalizeServerURL(raw string) (string, error) {
	text := strings.TrimSpace(raw)
	if text == "" {
		return "", nil
	}
	parsed, err := url.Parse(text)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		return "", fmt.Errorf("server URL must be http(s) with a host")
	}
	parsed.Fragment = ""
	out := strings.TrimRight(parsed.String(), "/")
	return out, nil
}

func effectiveRemoteURL(_ Settings) string {
	if v := strings.TrimSpace(os.Getenv("OCTOP_DESKTOP_URL")); v != "" {
		if u, err := normalizeServerURL(v); err == nil && u != "" {
			return u
		}
		return strings.TrimRight(v, "/")
	}
	return ""
}

func (st *settingsStore) get() Settings {
	st.mu.Lock()
	defer st.mu.Unlock()
	out := st.cur
	out.RemoteURLLocked = strings.TrimSpace(os.Getenv("OCTOP_DESKTOP_URL")) != ""
	if out.RemoteURLLocked {
		if u := effectiveRemoteURL(out); u != "" {
			out.ServerURL = u
		}
	}
	return out
}

func (st *settingsStore) save(next Settings) error {
	st.mu.Lock()
	defer st.mu.Unlock()
	if next.Port == 0 {
		next.Port = 8088
	}
	if strings.TrimSpace(os.Getenv("OCTOP_DESKTOP_URL")) != "" {
		next.ServerURL = st.cur.ServerURL
	} else {
		next.ServerURL = ""
	}
	u, err := normalizeServerURL(next.ServerURL)
	if err != nil {
		return err
	}
	next.ServerURL = u
	next.RemoteURLLocked = false
	if err := os.MkdirAll(octopHome(), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(next, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(settingsPath(), data, 0o644); err != nil {
		return err
	}
	next.RemoteURLLocked = strings.TrimSpace(os.Getenv("OCTOP_DESKTOP_URL")) != ""
	st.cur = next
	return nil
}

func greenPlat() string {
	osName := runtime.GOOS
	arch := runtime.GOARCH
	switch osName {
	case "darwin":
		osName = "darwin"
	case "windows":
		osName = "windows"
	default:
		osName = "linux"
	}
	switch arch {
	case "arm64":
		arch = "arm64"
	default:
		arch = "amd64"
	}
	return osName + "-" + arch
}
