package main

import (
	"context"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
	"time"
)

// dashboardProxyAddr is a stable loopback origin so WebView localStorage
// (JWT / remember-me) survives desktop restarts. :0 would pick a new port
// every launch and look like a new site.
const dashboardProxyAddr = "127.0.0.1:18761"

type dashboardProxyHooks struct {
	OnBearer  func(token string)
	OnRenewed func(token string)
}

func startDashboardProxy(remote string, hooks ...dashboardProxyHooks) (localURL string, srv *http.Server, err error) {
	return startDashboardProxyOn(dashboardProxyAddr, remote, hooks...)
}

func startDashboardProxyOn(listenAddr, remote string, hooks ...dashboardProxyHooks) (localURL string, srv *http.Server, err error) {
	target, err := url.Parse(strings.TrimRight(strings.TrimSpace(remote), "/"))
	if err != nil {
		return "", nil, err
	}
	if target.Scheme == "" || target.Host == "" {
		return "", nil, errInvalidRemoteURL(remote)
	}
	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		return "", nil, err
	}
	localHost := ln.Addr().String()
	var hook dashboardProxyHooks
	if len(hooks) > 0 {
		hook = hooks[0]
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.FlushInterval = 100 * time.Millisecond
	proxy.Director = func(req *http.Request) {
		req.URL.Scheme = target.Scheme
		req.URL.Host = target.Host
		req.Host = target.Host
		if req.Header.Get("X-Forwarded-Host") == "" {
			req.Header.Set("X-Forwarded-Host", localHost)
		}
		req.Header.Set("X-Forwarded-Proto", "http")
		captureProxyBearer(req, hook.OnBearer)
	}
	proxy.ModifyResponse = func(resp *http.Response) error {
		rewriteProxyLocation(resp, target.Host, localHost)
		if hook.OnRenewed != nil {
			if next := resp.Header.Get("X-Octop-Access-Token"); next != "" {
				hook.OnRenewed(next)
			}
		}
		return nil
	}
	srv = &http.Server{Handler: proxy}
	go func() { _ = srv.Serve(ln) }()
	return "http://" + localHost, srv, nil
}

func rewriteProxyLocation(resp *http.Response, remoteHost, localHost string) {
	loc := resp.Header.Get("Location")
	if loc == "" {
		return
	}
	u, err := url.Parse(loc)
	if err != nil {
		return
	}
	if u.Host == "" || strings.EqualFold(u.Host, remoteHost) {
		u.Scheme = "http"
		u.Host = localHost
		resp.Header.Set("Location", u.String())
	}
}

func closeDashboardProxy(srv *http.Server) {
	if srv == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
	_ = srv.Close()
}

func captureProxyBearer(req *http.Request, onBearer func(string)) {
	if onBearer == nil || req == nil {
		return
	}
	path := req.URL.Path
	if !strings.HasPrefix(path, "/api/") || strings.HasPrefix(path, "/api/auth/login") {
		return
	}
	auth := req.Header.Get("Authorization")
	if len(auth) < 8 || !strings.EqualFold(auth[:7], "Bearer ") {
		return
	}
	token := strings.TrimSpace(auth[7:])
	if token != "" {
		onBearer(token)
	}
}

func errInvalidRemoteURL(raw string) error {
	return &invalidRemoteURLError{raw: raw}
}

type invalidRemoteURLError struct{ raw string }

func (e *invalidRemoteURLError) Error() string {
	return "invalid company server URL: " + e.raw
}
