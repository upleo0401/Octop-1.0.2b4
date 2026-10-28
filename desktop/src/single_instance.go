package main

import "sync"

// activateRelay stores the late-bound "show the running window" callback.
// The lock is taken before windows exist; main registers the callback after.
type activateRelay struct {
	mu sync.Mutex
	fn func()
}

func (r *activateRelay) set(fn func()) {
	r.mu.Lock()
	r.fn = fn
	r.mu.Unlock()
}

func (r *activateRelay) fire() {
	r.mu.Lock()
	fn := r.fn
	r.mu.Unlock()
	if fn != nil {
		fn()
	}
}
