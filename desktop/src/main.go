package main

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/wailsapp/wails/v3/pkg/application"
	"github.com/wailsapp/wails/v3/pkg/events"
)

//go:embed assets/*
var assets embed.FS

const trayDoubleClick = 400 * time.Millisecond

// App is the Wails service bound to the shell UI.
type App struct {
	app            *application.App
	window         *application.WebviewWindow
	settingsWindow *application.WebviewWindow
	store          *settingsStore
	sleep          *sleepGuard
	cmd            *exec.Cmd
	proxySrv       *http.Server
	mu             sync.Mutex
	quitting       bool

	trayClickMu    sync.Mutex
	lastTrayClick  time.Time
	trayClickTimer *time.Timer

	bootStarted bool
	bootState   BootState
}

type BootState struct {
	Status       string `json:"status"`
	DashboardURL string `json:"dashboardUrl"`
	Error        bool   `json:"error"`
}

func (a *App) ServiceName() string { return "desktop" }

func (a *App) ServiceStartup(context.Context, application.ServiceOptions) error { return nil }

func (a *App) ServiceShutdown() error {
	a.sleep.stop()
	a.mu.Lock()
	cmd := a.cmd
	a.cmd = nil
	proxy := a.proxySrv
	a.proxySrv = nil
	a.mu.Unlock()
	stopOctop(cmd)
	if proxy != nil {
		closeDashboardProxy(proxy)
	}
	return nil
}

func (a *App) replaceProxy(srv *http.Server) {
	a.mu.Lock()
	prev := a.proxySrv
	a.proxySrv = srv
	a.mu.Unlock()
	if prev != nil {
		closeDashboardProxy(prev)
	}
}

func (a *App) GetSettings() Settings {
	return a.store.get()
}

func (a *App) GetSettingsStatus() (Settings, error) {
	s := a.store.get()
	if a.app == nil {
		return s, nil
	}
	status, err := a.app.Autostart.Status()
	if err != nil {
		return s, fmt.Errorf("read autostart status: %w", err)
	}
	if s.Autostart != status.Enabled {
		s.Autostart = status.Enabled
		if err := a.store.save(s); err != nil {
			return s, err
		}
	}
	return s, nil
}

func (a *App) SaveSettings(next Settings) (Settings, error) {
	cur, err := a.GetSettingsStatus()
	if err != nil {
		return cur, err
	}
	autostart, err := a.setAutostart(next.Autostart)
	if err != nil {
		return cur, err
	}
	if err := a.sleep.set(next.PreventSleep); err != nil {
		if _, rollbackErr := a.setAutostart(cur.Autostart); rollbackErr != nil {
			log.Printf("rollback autostart after sleep prevention failure: %v", rollbackErr)
		}
		return cur, err
	}
	next.Autostart = autostart
	prevRemote := effectiveRemoteURL(cur)
	if err := a.store.save(next); err != nil {
		return cur, err
	}
	saved := a.store.get()
	a.applyDashboardPrefs(saved)
	if effectiveRemoteURL(saved) != prevRemote {
		go a.boot()
	}
	return saved, nil
}

func (a *App) ShowMain() {
	a.showWindow()
}

func (a *App) GetBootState() BootState {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.bootState
}

func (a *App) SplashReady() {
	a.startBootOnce()
	a.replayBootEvents()
}

func (a *App) startBootOnce() {
	a.mu.Lock()
	if a.bootStarted {
		a.mu.Unlock()
		return
	}
	a.bootStarted = true
	a.mu.Unlock()
	go a.boot()
}

func (a *App) replayBootEvents() {
	if a.app == nil {
		return
	}
	a.mu.Lock()
	st := a.bootState
	a.mu.Unlock()
	if st.Status != "" {
		a.app.Event.Emit("desktop:status", st.Status)
	}
	if st.DashboardURL != "" {
		a.app.Event.Emit("desktop:dashboard", st.DashboardURL)
	}
}

func statusLooksFailed(msg string) bool {
	return strings.Contains(msg, "未就绪") ||
		strings.Contains(msg, "did not become ready") ||
		strings.Contains(msg, "无法连接") ||
		strings.Contains(msg, "Could not connect") ||
		strings.Contains(msg, "invalid company server")
}

func (a *App) OpenServerInBrowser() error {
	a.mu.Lock()
	url := strings.TrimSpace(a.bootState.DashboardURL)
	a.mu.Unlock()
	if url == "" && a.store != nil {
		s := a.store.get()
		if remote := effectiveRemoteURL(s); remote != "" {
			url = remote
		} else {
			url = dashboardURL(s.Port)
		}
	}
	if url == "" {
		return fmt.Errorf("AimiOct is not ready yet")
	}
	return a.OpenExternal(url)
}

func (a *App) HideSettings() {
	if a.settingsWindow == nil {
		return
	}
	a.settingsWindow.Hide()
}

func (a *App) Quit() {
	a.requestQuit()
}

func (a *App) setAutostart(on bool) (bool, error) {
	if a.app == nil {
		return false, fmt.Errorf("autostart is unavailable before the application starts")
	}
	if on {
		if err := a.app.Autostart.Enable(); err != nil {
			return false, fmt.Errorf("enable autostart: %w", err)
		}
	} else if err := a.app.Autostart.Disable(); err != nil {
		return false, fmt.Errorf("disable autostart: %w", err)
	}
	status, err := a.app.Autostart.Status()
	if err != nil {
		return false, fmt.Errorf("read autostart status: %w", err)
	}
	if status.Enabled != on {
		return status.Enabled, fmt.Errorf("autostart state did not update")
	}
	return status.Enabled, nil
}

func (a *App) applyDashboardPrefs(s Settings) {
	if a.window == nil {
		return
	}
	js := fmt.Sprintf(
		`(function(){try{localStorage.setItem('octop:ui-locale',%s);}catch(e){}})();`,
		jsonString(string(s.Locale)),
	)
	a.window.ExecJS(js)
}

func jsonString(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

func (a *App) setStatus(msg string) {
	a.mu.Lock()
	a.bootState.Status = msg
	a.bootState.Error = statusLooksFailed(msg)
	a.mu.Unlock()
	if a.app == nil {
		return
	}
	a.app.Event.Emit("desktop:status", msg)
}

func (a *App) boot() {
	locale := LocaleEN
	var s Settings
	if a.store != nil {
		s = a.store.get()
		locale = s.Locale
	}
	if url := effectiveRemoteURL(s); url != "" {
		a.mu.Lock()
		stopOctop(a.cmd)
		a.cmd = nil
		a.mu.Unlock()
		log.Printf("connecting to %s", url)
		a.setStatus(desktopText(locale, copyStatusConnecting))
		a.showWindow()
		if err := waitHealth(locale, url, 20*time.Second); err != nil {
			log.Printf("health failed: %v", err)
			a.setStatus(err.Error())
			if a.settingsWindow != nil {
				a.settingsWindow.Show()
				a.settingsWindow.Focus()
			}
			return
		}
		a.replaceProxy(nil)
		local, srv, err := startDashboardProxy(url)
		if err != nil {
			log.Printf("proxy: %v", err)
			a.setStatus(err.Error())
			return
		}
		a.replaceProxy(srv)
		log.Printf("proxy %s -> %s", local, url)
		a.showDashboard(local)
		return
	}
	if !allowLocalRuntime() {
		a.mu.Lock()
		stopOctop(a.cmd)
		a.cmd = nil
		a.mu.Unlock()
		a.setStatus(desktopText(locale, copyStatusNeedServerURL))
		if a.settingsWindow != nil {
			a.settingsWindow.Show()
			a.settingsWindow.Focus()
		}
		return
	}
	a.setStatus(desktopText(locale, copyStatusCheckingRuntime))
	if err := ensurePortable(locale, a.setStatus); err != nil {
		a.setStatus(err.Error())
		return
	}
	root := portableDir()
	a.mu.Lock()
	stopOctop(a.cmd)
	cmd, err := startOctop(root, s.Port)
	a.cmd = cmd
	a.mu.Unlock()
	if err != nil {
		a.setStatus(err.Error())
		return
	}
	base := dashboardURL(s.Port)
	a.setStatus(desktopText(locale, copyStatusStartingService))
	if err := waitHealth(locale, base, 2*time.Minute); err != nil {
		a.setStatus(err.Error())
		return
	}
	a.showDashboard(base)
}

func (a *App) showDashboard(base string) {
	if a.window == nil {
		return
	}
	target := strings.TrimRight(base, "/") + "/"
	log.Printf("embed dashboard %s", target)
	a.mu.Lock()
	a.bootState.DashboardURL = target
	a.bootState.Error = false
	a.mu.Unlock()
	if a.app != nil {
		a.app.Event.Emit("desktop:dashboard", target)
	}
	a.showWindow()
	a.scheduleDragOverlay()
	s := a.store.get()
	go func() {
		time.Sleep(800 * time.Millisecond)
		a.applyDashboardPrefs(s)
	}()
	a.setStatus(desktopText(s.Locale, copyStatusReady))
}

func (a *App) hideToTray() {
	if a.window == nil {
		return
	}
	a.window.Hide()
}

func (a *App) showWindow() {
	if a.window == nil {
		return
	}
	if a.window.IsMinimised() {
		a.window.UnMinimise()
	}
	a.window.Show()
	a.window.Focus()
}

func (a *App) toggleMainWindow() {
	if a.window == nil {
		return
	}
	if a.window.IsVisible() && !a.window.IsMinimised() {
		a.hideToTray()
		return
	}
	a.showWindow()
}

func (a *App) onTrayLeftClick() {
	a.trayClickMu.Lock()
	defer a.trayClickMu.Unlock()
	if a.trayClickTimer != nil {
		a.trayClickTimer.Stop()
		a.trayClickTimer = nil
	}
	now := time.Now()
	if !a.lastTrayClick.IsZero() && now.Sub(a.lastTrayClick) < trayDoubleClick {
		a.lastTrayClick = time.Time{}
		go a.toggleMainWindow()
		return
	}
	a.lastTrayClick = now
	a.trayClickTimer = time.AfterFunc(trayDoubleClick, func() {
		a.trayClickMu.Lock()
		a.trayClickTimer = nil
		a.trayClickMu.Unlock()
		a.showWindow()
	})
}

func (a *App) installDragOverlay() {
	if a.window == nil {
		return
	}
	a.window.ExecJS(dragOverlayJS())
}

func (a *App) scheduleDragOverlay() {
	go func() {
		for range 40 {
			time.Sleep(250 * time.Millisecond)
			a.installDragOverlay()
			a.installExternalLinks()
		}
	}()
}

func (a *App) requestQuit() {
	a.mu.Lock()
	a.quitting = true
	a.mu.Unlock()
	if a.app != nil {
		a.app.Quit()
	}
}

func main() {
	initDesktopLog()
	activate := &activateRelay{}
	releaseInstance, ok := acquireSingleInstance(activate.fire)
	if !ok {
		log.Printf("another AimiOct desktop is already running; activating it")
		os.Exit(0)
	}
	defer releaseInstance()
	store := &settingsStore{cur: loadSettings()}
	if _, err := os.Stat(settingsPath()); err != nil {
		if saveErr := store.save(store.get()); saveErr != nil {
			log.Printf("save default settings: %v", saveErr)
		}
	}
	api := &App{
		store: store,
		sleep: &sleepGuard{},
	}

	app := application.New(application.Options{
		Name:        "AimiOct",
		Description: "AimiOct desktop",
		Services: []application.Service{
			application.NewService(api),
		},
		Assets: application.AssetOptions{
			Handler: application.BundledAssetFileServer(assets),
		},
		Windows: application.WindowsOptions{
			DisableQuitOnLastWindowClosed: true,
			WebviewUserDataPath:           webviewUserDataDir(),
		},
		Linux: application.LinuxOptions{
			DisableQuitOnLastWindowClosed: true,
		},
		Mac: application.MacOptions{
			ApplicationShouldTerminateAfterLastWindowClosed: false,
		},
	})
	api.app = app
	attachOpenURLEventListener(app, api.OpenExternal)
	app.Event.OnApplicationEvent(events.Common.ApplicationStarted, func(_ *application.ApplicationEvent) {
		applyAppIcon(app)
		applySettingsWindowSize(app, api.settingsWindow)
		go func() {
			time.Sleep(2 * time.Second)
			api.startBootOnce()
		}()
	})

	win := app.Window.NewWithOptions(application.WebviewWindowOptions{
		Title:                "AimiOct",
		Width:                1200,
		Height:               800,
		URL:                  "/",
		Frameless:            true,
		AllowSimpleEventEmit: true,
		BackgroundColour:     application.NewRGB(247, 248, 250),
	})
	api.window = win
	app.Event.On("desktop:toggle-maximise", func(_ *application.CustomEvent) {
		win.ToggleMaximise()
	})
	app.Event.On("desktop:minimise", func(_ *application.CustomEvent) {
		win.Minimise()
	})
	app.Event.On("desktop:close", func(_ *application.CustomEvent) {
		api.hideToTray()
	})
	installDragOverlay := func(_ *application.WindowEvent) { api.scheduleDragOverlay() }
	win.OnWindowEvent(events.Mac.WebViewDidFinishNavigation, installDragOverlay)
	win.OnWindowEvent(events.Windows.WebViewNavigationCompleted, installDragOverlay)
	win.OnWindowEvent(events.Linux.WindowLoadFinished, installDragOverlay)
	settingsWin := app.Window.NewWithOptions(application.WebviewWindowOptions{
		Title:            "AimiOct 设置",
		Width:            settingsWindowWidth,
		Height:           settingsWindowOuterHeight(),
		URL:              "/?settings=1",
		Hidden:           true,
		Frameless:        true,
		AlwaysOnTop:      true,
		DisableResize:    true,
		BackgroundColour: application.NewRGB(255, 255, 255),
		Windows: application.WindowsWindow{
			HiddenOnTaskbar: true,
		},
	})
	api.settingsWindow = settingsWin
	activate.set(func() {
		restoreMainAfterDockClick(api.window, api.settingsWindow)
	})
	app.Event.RegisterApplicationEventHook(events.Mac.ApplicationShouldHandleReopen, func(event *application.ApplicationEvent) {
		event.Cancel()
		restoreMainAfterDockClick(api.window, api.settingsWindow)
	})

	win.RegisterHook(events.Common.WindowClosing, func(e *application.WindowEvent) {
		api.mu.Lock()
		quit := api.quitting
		api.mu.Unlock()
		if quit {
			return
		}
		e.Cancel()
		api.hideToTray()
	})
	win.OnWindowEvent(events.Common.WindowMinimise, func(_ *application.WindowEvent) {
		if api.store.get().MinimizeToTray {
			api.hideToTray()
		}
	})
	settingsWin.RegisterHook(events.Common.WindowClosing, func(e *application.WindowEvent) {
		e.Cancel()
		settingsWin.Hide()
	})
	settingsWin.OnWindowEvent(events.Common.WindowLostFocus, func(_ *application.WindowEvent) {
		settingsWin.Hide()
	})

	tray := app.SystemTray.New()
	applyTrayIcon(tray)
	tray.SetTooltip("AimiOct")
	tray.AttachWindow(settingsWin).WindowOffset(6)
	showSettings := func() {
		applySettingsWindowSize(app, settingsWin)
		tray.ShowWindow()
	}
	if trayLeftClickShowsSettings(runtime.GOOS) {
		tray.OnClick(showSettings)
	} else {
		tray.OnClick(func() { api.onTrayLeftClick() })
	}
	tray.OnRightClick(showSettings)

	if _, err := api.setAutostart(store.get().Autostart); err != nil {
		log.Printf("sync autostart: %v", err)
	}
	if err := api.sleep.set(store.get().PreventSleep); err != nil {
		log.Printf("enable sleep prevention: %v", err)
	}

	api.scheduleDragOverlay()

	if err := app.Run(); err != nil {
		log.Printf("app run: %v", err)
		alertError("AimiOct 无法启动", err.Error())
		os.Exit(1)
	}
}
