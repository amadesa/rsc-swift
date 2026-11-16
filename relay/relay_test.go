package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

const testToken = "test-token-0123456789"

// echoServer stands in for a game server: it echoes everything back, and
// hangs up when it receives "bye".
func echoServer(t *testing.T) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })

	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				buf := make([]byte, 4096)
				for {
					n, err := conn.Read(buf)
					if err != nil {
						return
					}
					if bytes.Contains(buf[:n], []byte("bye")) {
						return
					}
					conn.Write(buf[:n])
				}
			}()
		}
	}()

	return listener.Addr().String()
}

type client struct {
	t    *testing.T
	base string
}

func newTestRelay(t *testing.T, allow string, idle time.Duration) (*client, *relay) {
	t.Helper()
	r := newRelay(testToken, parseAllow(allow), idle)
	server := httptest.NewServer(r.routes())
	t.Cleanup(server.Close)
	return &client{t: t, base: server.URL}, r
}

func (c *client) do(method, path string, body []byte, authed bool) (int, []byte) {
	c.t.Helper()
	req, err := http.NewRequest(method, c.base+path, bytes.NewReader(body))
	if err != nil {
		c.t.Fatal(err)
	}
	if authed {
		req.Header.Set("Authorization", "Bearer "+testToken)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, data
}

func (c *client) open(address string) string {
	c.t.Helper()
	host, port, _ := net.SplitHostPort(address)
	status, body := c.do("POST", "/v1/sessions",
		[]byte(fmt.Sprintf(`{"host":%q,"port":%s}`, host, port)), true)
	if status != http.StatusCreated {
		c.t.Fatalf("open: %d %s", status, body)
	}
	var created struct{ ID string }
	json.Unmarshal(body, &created)
	return created.ID
}

func (c *client) send(id string, at int, data string) int {
	c.t.Helper()
	status, _ := c.do("POST", fmt.Sprintf("/v1/sessions/%s/send?at=%d", id, at), []byte(data), true)
	return status
}

func (c *client) recv(id string, from int, waitMs int) (int, string) {
	c.t.Helper()
	status, body := c.do("GET", fmt.Sprintf("/v1/sessions/%s/recv?from=%d&wait=%d", id, from, waitMs), nil, true)
	return status, string(body)
}

// recvAll polls until want bytes arrive (the echo can come back in pieces).
func (c *client) recvAll(id string, from int, want int) string {
	c.t.Helper()
	got := ""
	for len(got) < want {
		status, data := c.recv(id, from, 2000)
		if status != http.StatusOK {
			c.t.Fatalf("recv: %d", status)
		}
		got += data
		from += len(data)
	}
	return got
}

func TestAuthAndHealth(t *testing.T) {
	c, _ := newTestRelay(t, echoServer(t), time.Minute)

	if status, _ := c.do("GET", "/v1/health", nil, false); status != http.StatusOK {
		t.Errorf("health without token: %d, want 200", status)
	}
	if status, _ := c.do("POST", "/v1/sessions", []byte(`{}`), false); status != http.StatusUnauthorized {
		t.Errorf("open without token: %d, want 401", status)
	}
}

func TestAllowList(t *testing.T) {
	c, _ := newTestRelay(t, echoServer(t), time.Minute)

	status, _ := c.do("POST", "/v1/sessions", []byte(`{"host":"example.com","port":80}`), true)
	if status != http.StatusForbidden {
		t.Errorf("open to a host not on the list: %d, want 403", status)
	}
}

func TestRoundTrip(t *testing.T) {
	address := echoServer(t)
	c, _ := newTestRelay(t, address, time.Minute)
	id := c.open(address)

	if status := c.send(id, 0, "hello"); status != http.StatusNoContent {
		t.Fatalf("send: %d", status)
	}
	if got := c.recvAll(id, 0, 5); got != "hello" {
		t.Errorf("recv = %q, want hello", got)
	}

	// nothing more: a short wait returns empty
	if status, data := c.recv(id, 5, 100); status != http.StatusOK || data != "" {
		t.Errorf("idle recv = %d %q, want 200 \"\"", status, data)
	}
}

func TestRetriedSendIsNotRepeated(t *testing.T) {
	address := echoServer(t)
	c, _ := newTestRelay(t, address, time.Minute)
	id := c.open(address)

	c.send(id, 0, "hel")
	// the client didn't see the first response, so it resends from 0 with more
	c.send(id, 0, "hello")
	// and an exact repeat
	c.send(id, 0, "hello")

	if got := c.recvAll(id, 0, 5); got != "hello" {
		t.Errorf("server received %q, want hello exactly once", got)
	}
	if status, data := c.recv(id, 5, 200); data != "" {
		t.Errorf("extra bytes after a retried send: %d %q", status, data)
	}
}

func TestLostResponseCanBeFetchedAgain(t *testing.T) {
	address := echoServer(t)
	c, _ := newTestRelay(t, address, time.Minute)
	id := c.open(address)

	c.send(id, 0, "world")
	first := c.recvAll(id, 0, 5)
	// pretend that response was lost: asking for offset 0 again still works
	if again := c.recvAll(id, 0, 5); again != first {
		t.Errorf("refetch = %q, want %q", again, first)
	}
	// moving on to offset 5 acknowledges it, so 0 is gone
	c.recv(id, 5, 50)
	if status, _ := c.recv(id, 0, 50); status != http.StatusConflict {
		t.Errorf("recv of acknowledged data: %d, want 409", status)
	}
}

func TestOffsetsPastTheStream(t *testing.T) {
	address := echoServer(t)
	c, _ := newTestRelay(t, address, time.Minute)
	id := c.open(address)

	if status := c.send(id, 100, "x"); status != http.StatusConflict {
		t.Errorf("send past the stream: %d, want 409", status)
	}
	if status, _ := c.recv(id, 100, 50); status != http.StatusConflict {
		t.Errorf("recv past the stream: %d, want 409", status)
	}
}

func TestServerHangingUp(t *testing.T) {
	address := echoServer(t)
	c, _ := newTestRelay(t, address, time.Minute)
	id := c.open(address)

	c.send(id, 0, "bye")
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if status, _ := c.recv(id, 0, 500); status == http.StatusGone {
			return
		}
	}
	t.Error("recv never reported the closed connection with 410")
}

func TestIdleSessionsClose(t *testing.T) {
	address := echoServer(t)
	c, r := newTestRelay(t, address, 50*time.Millisecond)
	id := c.open(address)

	time.Sleep(100 * time.Millisecond)
	// run one reaping pass directly rather than waiting for the ticker
	r.mu.Lock()
	s := r.sessions[id]
	r.mu.Unlock()
	if s.idleFor() > r.idle {
		r.close(s, "closed after going idle")
	}

	if status, _ := c.recv(id, 0, 10); status != http.StatusNotFound {
		t.Errorf("recv on an idle-closed session: %d, want 404", status)
	}
}

func TestBadRequests(t *testing.T) {
	address := echoServer(t)
	c, _ := newTestRelay(t, address, time.Minute)
	id := c.open(address)

	if status, _ := c.do("POST", "/v1/sessions/"+id+"/send", []byte("x"), true); status != http.StatusBadRequest {
		t.Errorf("send without ?at=: %d, want 400", status)
	}
	if status, _ := c.do("GET", "/v1/sessions/nope/recv?from=0", nil, true); status != http.StatusNotFound {
		t.Errorf("unknown session: %d, want 404", status)
	}
	big := strings.Repeat("x", maxSendBytes+1)
	if status, _ := c.do("POST", "/v1/sessions/"+id+"/send?at=0", []byte(big), true); status != http.StatusRequestEntityTooLarge {
		t.Errorf("oversized send: %d, want 413", status)
	}
}

// captureLog collects what the relay logs during a test.
func captureLog(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })
	return &buf
}

func TestCheck(t *testing.T) {
	game := echoServer(t)
	c, _ := newTestRelay(t, game, time.Minute)

	if status, _ := c.do("GET", "/v1/check", nil, false); status != http.StatusUnauthorized {
		t.Errorf("check without token: %d, want 401", status)
	}

	host, port, _ := net.SplitHostPort(game)
	status, body := c.do("GET", "/v1/check?host="+host+"&port="+port, nil, true)
	if status != http.StatusOK {
		t.Fatalf("check: %d %s", status, body)
	}

	var result struct {
		Version string
		Servers []serverCheck
	}
	json.Unmarshal(body, &result)
	if result.Version != version || len(result.Servers) != 1 ||
		!result.Servers[0].Allowed || !result.Servers[0].Reachable {
		t.Errorf("check of a running server: %s", body)
	}

	_, body = c.do("GET", "/v1/check?host=example.com&port=80", nil, true)
	json.Unmarshal(body, &result)
	if len(result.Servers) != 1 || result.Servers[0].Allowed || result.Servers[0].Reachable {
		t.Errorf("check of a server not on the list: %s", body)
	}
}

func TestCheckOfAServerThatIsDown(t *testing.T) {
	listener, _ := net.Listen("tcp", "127.0.0.1:0")
	down := listener.Addr().String()
	listener.Close()

	c, _ := newTestRelay(t, down, time.Minute)

	_, body := c.do("GET", "/v1/check", nil, true)
	var result struct{ Servers []serverCheck }
	json.Unmarshal(body, &result)
	if len(result.Servers) != 1 || result.Servers[0].Reachable || result.Servers[0].Error == "" {
		t.Errorf("check of a server that's down: %s", body)
	}
}

func TestRefusalsAreLoggedOnce(t *testing.T) {
	logged := captureLog(t)
	c, _ := newTestRelay(t, echoServer(t), time.Minute)

	for i := 0; i < 3; i++ {
		req, _ := http.NewRequest("POST", c.base+"/v1/sessions", strings.NewReader(`{}`))
		req.Header.Set("X-RSC-Client", "watch 0.2.0")
		req.Header.Set("Authorization", "Bearer wrong")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		if resp.Header.Get("X-RSC-Relay") != version {
			t.Errorf("X-RSC-Relay: %q, want %q", resp.Header.Get("X-RSC-Relay"), version)
		}
		resp.Body.Close()
	}

	text := logged.String()
	if strings.Count(text, "wrong access token") != 1 || !strings.Contains(text, "watch 0.2.0") {
		t.Errorf("log after three wrong tokens:\n%s", text)
	}
}

func TestSessionCloseIsExplained(t *testing.T) {
	logged := captureLog(t)
	game := echoServer(t)
	c, _ := newTestRelay(t, game, time.Minute)

	id := c.open(game)
	c.send(id, 0, "hi")
	c.recvAll(id, 0, 2)
	c.send(id, 2, "bye")

	for {
		if status, _ := c.recv(id, 2, 2000); status == http.StatusGone {
			break
		}
	}
	c.do("DELETE", "/v1/sessions/"+id, nil, true)

	text := logged.String()
	if !strings.Contains(text, "received 2 B") ||
		!strings.Contains(text, "the game server closed the connection") {
		t.Errorf("log of a session the server ended:\n%s", text)
	}
}
