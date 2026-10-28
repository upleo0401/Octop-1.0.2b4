package main

import (
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestDashboardProxyForwardsHealth(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/health" {
			t.Fatalf("path=%s", r.URL.Path)
		}
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"ok":true}`)
	}))
	t.Cleanup(upstream.Close)

	local, srv, err := startDashboardProxyOn("127.0.0.1:0", upstream.URL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = srv.Close() })

	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get(strings.TrimRight(local, "/") + "/api/health")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d", resp.StatusCode)
	}
}

func TestDashboardProxyStableAddr(t *testing.T) {
	if dashboardProxyAddr != "127.0.0.1:18761" {
		t.Fatalf("stable proxy origin changed: %s", dashboardProxyAddr)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	_ = ln.Close()

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(upstream.Close)

	local, srv, err := startDashboardProxyOn(addr, upstream.URL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { closeDashboardProxy(srv) })
	if local != "http://"+addr {
		t.Fatalf("local=%s want http://%s", local, addr)
	}
}

func TestCaptureProxyBearer(t *testing.T) {
	var got string
	req, err := http.NewRequest(http.MethodGet, "http://127.0.0.1/api/agents", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer abc.def")
	captureProxyBearer(req, func(token string) { got = token })
	if got != "abc.def" {
		t.Fatalf("got %q", got)
	}
}

func TestRewriteProxyLocation(t *testing.T) {
	resp := &http.Response{Header: make(http.Header)}
	resp.Header.Set("Location", "http://192.168.3.61:8088/login")
	rewriteProxyLocation(resp, "192.168.3.61:8088", "127.0.0.1:9")
	if got := resp.Header.Get("Location"); got != "http://127.0.0.1:9/login" {
		t.Fatalf("got %s", got)
	}
}
