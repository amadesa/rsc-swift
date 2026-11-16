package main

import (
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// limiter turns away an address after too many wrong tokens, so a relay on
// a public port can't be guessed at.
type limiter struct {
	mu       sync.Mutex
	failures map[string][]time.Time
}

const (
	failureWindow = 10 * time.Minute
	maxFailures   = 20
)

// blocked reports whether this address has used up its wrong tokens.
func (l *limiter) blocked(address string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.recent(address)) >= maxFailures
}

func (l *limiter) fail(address string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.failures == nil {
		l.failures = map[string][]time.Time{}
	}
	l.failures[address] = append(l.recent(address), time.Now())

	// forget addresses that went quiet
	if len(l.failures) > 4096 {
		for key := range l.failures {
			if len(l.recent(key)) == 0 {
				delete(l.failures, key)
			}
		}
	}
}

// recent drops failures older than the window. Called with mu held.
func (l *limiter) recent(address string) []time.Time {
	times := l.failures[address]
	cutoff := time.Now().Add(-failureWindow)
	kept := times[:0]
	for _, t := range times {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	if l.failures != nil {
		if len(kept) == 0 {
			delete(l.failures, address)
		} else {
			l.failures[address] = kept
		}
	}
	return kept
}

// remoteAddress is the client's IP. Behind Tailscale Funnel or another
// proxy on this machine, requests come from loopback with the client in
// X-Forwarded-For; that header is only believed from loopback.
func remoteAddress(req *http.Request) string {
	host, _, err := net.SplitHostPort(req.RemoteAddr)
	if err != nil {
		host = req.RemoteAddr
	}
	if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
		if forwarded := req.Header.Get("X-Forwarded-For"); forwarded != "" {
			first := strings.TrimSpace(strings.Split(forwarded, ",")[0])
			if net.ParseIP(first) != nil {
				return first
			}
		}
	}
	return host
}
