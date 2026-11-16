package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
)

// version is sent in the X-RSC-Relay header of every response, which also
// tells clients a reply came from the relay rather than from Tailscale
// Funnel standing in for a relay that isn't running.
const version = "0.3.0"

// how long the same failure from the same client is logged only once
const repeatWindow = 30 * time.Second

// clientName is what the app says it is ("watch 0.2.0") in X-RSC-Client,
// for the log.
func clientName(req *http.Request) string {
	name := strings.Map(func(r rune) rune {
		if r > unicode.MaxASCII || !unicode.IsPrint(r) {
			return -1
		}
		return r
	}, req.Header.Get("X-RSC-Client"))

	if name = strings.TrimSpace(name); name == "" {
		return "unknown client"
	}
	return name[:min(len(name), 40)]
}

// recorder keeps the status and error text a handler wrote, for the log.
type recorder struct {
	http.ResponseWriter
	status int
	body   []byte
}

func (r *recorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

func (r *recorder) Write(data []byte) (int, error) {
	if r.status == 0 {
		r.status = http.StatusOK
	}
	if r.status >= 400 && len(r.body) < 200 {
		r.body = append(r.body, data[:min(len(data), 200-len(r.body))]...)
	}
	return r.ResponseWriter.Write(data)
}

// Flush keeps long-polled responses streaming through the wrapper.
func (r *recorder) Flush() {
	if flusher, ok := r.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

// failureLog writes a line for every request the relay turns away, so a
// client that "can't connect" shows up here with the reason, collapsing
// repeats such as a client retrying with a wrong token.
type failureLog struct {
	mu   sync.Mutex
	seen map[string]*repeat
}

type repeat struct {
	last  time.Time
	count int
}

func (f *failureLog) record(client, method, path string, status int, message string) {
	// a session ending is logged as the session closes
	if status == http.StatusGone {
		return
	}

	line := fmt.Sprintf("%s: %s %s refused (%d %s): %s", client, method, routeName(path),
		status, http.StatusText(status), explain(status, message))

	f.mu.Lock()
	if f.seen == nil {
		f.seen = map[string]*repeat{}
	}
	entry := f.seen[line]
	now := time.Now()
	if entry != nil && now.Sub(entry.last) < repeatWindow {
		entry.count++
		f.mu.Unlock()
		return
	}
	suppressed := 0
	if entry != nil {
		suppressed = entry.count
	}
	f.seen[line] = &repeat{last: now}
	f.mu.Unlock()

	if suppressed > 0 {
		line += fmt.Sprintf(" (and %d more like it before)", suppressed)
	}
	log.Print(line)
}

// routeName hides session ids, which only matter to the session's own lines.
func routeName(path string) string {
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) >= 3 && parts[0] == "v1" && parts[1] == "sessions" {
		parts[2] = "{id}"
	}
	return "/" + strings.Join(parts, "/")
}

// explain turns a refusal into what to do about it.
func explain(status int, message string) string {
	message = strings.TrimSpace(message)
	switch status {
	case http.StatusUnauthorized:
		if message == sharedTokenOff {
			return "the shared token is turned off (-shared-token=false). Pair the device: Accounts > Relay on the iPhone, or rsc-relay pair"
		}
		return "wrong access token. Copy the token from this relay's token file into the app's Relay settings"
	case http.StatusTooManyRequests:
		return "too many wrong tokens from this address; refused for up to 10 minutes"
	case http.StatusNotFound:
		if message == "no such session" {
			return "the session had already ended (expired after going idle, or the game server hung up)"
		}
		return "no such address on the relay. Check the app's relay URL has no extra path"
	}
	return message
}

// logged wraps the api so every refusal is logged and every response says
// it came from the relay.
func (r *relay) logged(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		w.Header().Set("X-RSC-Relay", version)

		rec := &recorder{ResponseWriter: w}
		next.ServeHTTP(rec, req)

		if rec.status >= 400 {
			r.failures.record(clientName(req), req.Method, req.URL.Path, rec.status, string(rec.body))
		}
	})
}

// serverCheck is one game server's result in /v1/check.
type serverCheck struct {
	Address   string `json:"address"`
	Allowed   bool   `json:"allowed"`
	Reachable bool   `json:"reachable"`
	Millis    int64  `json:"ms,omitempty"`
	Error     string `json:"error,omitempty"`
}

// check answers GET /v1/check[?host=&port=]: getting here with the right
// token already shows the app can reach the relay; this adds whether the
// relay can reach the game server (or, without a host, every allowed one).
func (r *relay) check(w http.ResponseWriter, req *http.Request) {
	var addresses []string

	if host := req.URL.Query().Get("host"); host != "" {
		port, err := strconv.Atoi(req.URL.Query().Get("port"))
		if err != nil {
			http.Error(w, "bad ?port=", http.StatusBadRequest)
			return
		}
		addresses = []string{net.JoinHostPort(strings.ToLower(host), strconv.Itoa(port))}
	} else {
		for address := range r.allowed {
			addresses = append(addresses, address)
		}
	}

	results := make([]serverCheck, len(addresses))
	var wait sync.WaitGroup

	for i, address := range addresses {
		results[i] = serverCheck{Address: address, Allowed: r.allowed[address]}
		if !results[i].Allowed {
			continue
		}

		wait.Add(1)
		go func(result *serverCheck) {
			defer wait.Done()
			ctx, cancel := context.WithTimeout(req.Context(), checkTimeout)
			defer cancel()

			start := time.Now()
			conn, err := (&net.Dialer{}).DialContext(ctx, "tcp", result.Address)
			if err != nil {
				result.Error = dialError(err)
				return
			}
			conn.Close()
			result.Reachable = true
			result.Millis = time.Since(start).Milliseconds()
		}(&results[i])
	}
	wait.Wait()

	for _, result := range results {
		if !result.Reachable {
			reason := result.Error
			if !result.Allowed {
				reason = "not in the allow list"
			}
			log.Printf("%s: check: %s isn't reachable: %s", clientName(req), result.Address, reason)
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"version":  version,
		"sessions": r.sessionCount(),
		"servers":  results,
	})
}

const checkTimeout = 5 * time.Second

// dialError says why the game server couldn't be reached, without Go's
// "dial tcp 1.2.3.4:43596:" prefix.
func dialError(err error) string {
	message := err.Error()
	if i := strings.LastIndex(message, ": "); i >= 0 {
		message = message[i+2:]
	}
	if strings.Contains(message, "deadline exceeded") || strings.Contains(message, "i/o timeout") {
		return "timed out"
	}
	return message
}

// size is a byte count for the log.
func size(n int64) string {
	switch {
	case n >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(n)/(1<<20))
	case n >= 1<<10:
		return fmt.Sprintf("%.1f KB", float64(n)/(1<<10))
	}
	return fmt.Sprintf("%d B", n)
}
