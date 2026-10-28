package main

import (
	"sync/atomic"
	"testing"
	"time"
)

func TestActivateRelayFiresAfterSet(t *testing.T) {
	r := &activateRelay{}
	r.fire()
	var n atomic.Int32
	r.set(func() { n.Add(1) })
	r.fire()
	r.fire()
	if n.Load() != 2 {
		t.Fatalf("got %d fires, want 2", n.Load())
	}
}

func TestSecondInstanceActivatesFirst(t *testing.T) {
	got := make(chan struct{}, 1)
	onActivate := func() {
		select {
		case got <- struct{}{}:
		default:
		}
	}

	release, ok := acquireTestInstance(t, onActivate)
	if !ok {
		t.Fatal("first instance should acquire the lock")
	}
	defer release()

	time.Sleep(50 * time.Millisecond)
	_, second := acquireTestInstance(t, nil)
	if second {
		t.Fatal("second instance must not start another process")
	}

	select {
	case <-got:
	case <-time.After(2 * time.Second):
		t.Fatal("first instance did not receive the activate signal")
	}
}

