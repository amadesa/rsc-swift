package main

import (
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestIdentityIsKeptAndPinMatchesCertificate(t *testing.T) {
	dir := t.TempDir()

	first, err := loadOrCreateIdentity(dir)
	if err != nil {
		t.Fatal(err)
	}
	again, err := loadOrCreateIdentity(dir)
	if err != nil {
		t.Fatal(err)
	}
	if first.pin != again.pin {
		t.Fatalf("pin changed between starts: %s, then %s", first.pin, again.pin)
	}

	info, err := os.Stat(filepath.Join(dir, identityFile))
	if err != nil {
		t.Fatal(err)
	}
	if mode := info.Mode().Perm(); mode != 0o600 {
		t.Errorf("key file mode %o, want 600", mode)
	}

	certificate, err := first.certificate([]net.IP{net.ParseIP("192.168.4.20")})
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(certificate.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	if got := pinOf(leaf); got != first.pin {
		t.Errorf("certificate key %s, pin %s", got, first.pin)
	}
	if leaf.NotAfter.Sub(leaf.NotBefore) > 825*24*time.Hour {
		t.Errorf("certificate lasts longer than Apple accepts")
	}
}

func pinOf(certificate *x509.Certificate) string {
	sum := sha256.Sum256(certificate.RawSubjectPublicKeyInfo)
	return "sha256/" + base64.StdEncoding.EncodeToString(sum[:])
}

// An app that checks the pin instead of a certificate authority reaches the
// relay over HTTPS, and one expecting another key is turned away.
func TestHTTPSWithPinnedKey(t *testing.T) {
	id, err := loadOrCreateIdentity(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	certificate, err := id.certificate(nil)
	if err != nil {
		t.Fatal(err)
	}

	r := newRelay(testToken, parseAllow(""), time.Minute)
	r.info = func() relayInfo { return relayInfo{Version: version, Pin: id.pin} }

	server := httptest.NewUnstartedServer(r.routes())
	server.TLS = &tls.Config{Certificates: []tls.Certificate{certificate}}
	server.StartTLS()
	t.Cleanup(server.Close)

	pinned := func(pin string) *http.Client {
		return &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{
			InsecureSkipVerify: true, // replaced by the pin check
			VerifyPeerCertificate: func(raw [][]byte, _ [][]*x509.Certificate) error {
				leaf, err := x509.ParseCertificate(raw[0])
				if err != nil {
					return err
				}
				if pinOf(leaf) != pin {
					return errors.New("wrong key")
				}
				return nil
			},
		}}}
	}

	req, _ := http.NewRequest("GET", server.URL+"/v1/info", nil)
	req.Header.Set("Authorization", "Bearer "+testToken)
	resp, err := pinned(id.pin).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	var info relayInfo
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil || info.Pin != id.pin {
		t.Fatalf("info %+v, %v", info, err)
	}

	if _, err := pinned("sha256/AAAA").Get(server.URL + "/v1/health"); err == nil {
		t.Fatal("connected to a relay with a different key")
	}
}

func TestDeviceTokens(t *testing.T) {
	dir := t.TempDir()
	store, err := openDevices(dir)
	if err != nil {
		t.Fatal(err)
	}

	c, r := newTestRelay(t, "", time.Minute)
	r.devices = store

	d, token, err := store.add("Alex's Watch")
	if err != nil {
		t.Fatal(err)
	}

	get := func(token string) int {
		req, _ := http.NewRequest("GET", c.base+"/v1/check?host=example.com&port=1", nil)
		req.Header.Set("Authorization", "Bearer "+token)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}

	if status := get(token); status != http.StatusOK {
		t.Fatalf("paired device got %d", status)
	}

	data, _ := os.ReadFile(filepath.Join(dir, devicesFile))
	if strings.Contains(string(data), token) {
		t.Fatal("the token itself was stored")
	}

	// removed with the CLI while the relay runs: picked up from the file
	other, _ := openDevices(dir)
	if _, err := other.remove(d.ID); err != nil {
		t.Fatal(err)
	}
	store.mu.Lock()
	store.checked = time.Time{}
	store.mu.Unlock()

	if status := get(token); status != http.StatusUnauthorized {
		t.Fatalf("removed device got %d", status)
	}
}

func TestWrongTokensAreLimited(t *testing.T) {
	c, _ := newTestRelay(t, "", time.Minute)

	status := 0
	for i := 0; i <= maxFailures; i++ {
		req, _ := http.NewRequest("GET", c.base+"/v1/info", nil)
		req.Header.Set("Authorization", "Bearer wrong-token-0123456789")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		status = resp.StatusCode
	}
	if status != http.StatusTooManyRequests {
		t.Fatalf("after %d wrong tokens got %d", maxFailures+1, status)
	}

	// the right token is refused too until the window passes
	if status, _ := c.do("GET", "/v1/info", nil, true); status != http.StatusTooManyRequests {
		t.Fatalf("blocked address with the right token got %d", status)
	}
}

func TestAdvertisedAddresses(t *testing.T) {
	cases := map[string]string{
		"203.0.113.5":                       "https://203.0.113.5:8443",
		"203.0.113.5:9443":                  "https://203.0.113.5:9443",
		"2001:db8::1":                       "https://[2001:db8::1]:8443",
		"[2001:db8::1]:9443":                "https://[2001:db8::1]:9443",
		"https://rsc-relay.example.ts.net/": "https://rsc-relay.example.ts.net",
		"http://plain.example":              "",
	}
	for in, want := range cases {
		if got := normalizeAdvertised(in, 8443); got != want {
			t.Errorf("%q: got %q, want %q", in, got, want)
		}
	}

	kinds := map[string]string{
		"192.168.4.20":      "lan",
		"10.0.0.2":          "lan",
		"100.78.190.64":     "tailscale",
		"fd7a:115c:a1e0::1": "tailscale",
		"2600:1700::5":      "ipv6",
	}
	for ip, want := range kinds {
		if got := addressKind(net.ParseIP(ip)); got != want {
			t.Errorf("%s: got %q, want %q", ip, got, want)
		}
	}
}

// With the shared token off, only paired devices get in, and an old copy of
// the shared token is told to pair rather than counted as a guess.
func TestSharedTokenOff(t *testing.T) {
	store, err := openDevices(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	c, r := newTestRelay(t, "", time.Minute)
	r.devices = store
	r.sharedOff = true
	_, token, err := store.add("iPhone")
	if err != nil {
		t.Fatal(err)
	}

	get := func(token string) (int, string) {
		req, _ := http.NewRequest("GET", c.base+"/v1/check?host=example.com&port=1", nil)
		req.Header.Set("Authorization", "Bearer "+token)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, strings.TrimSpace(string(body))
	}

	if status, _ := get(token); status != http.StatusOK {
		t.Fatalf("paired device got %d", status)
	}
	for i := 0; i <= maxFailures; i++ {
		if status, body := get(testToken); status != http.StatusUnauthorized || body != sharedTokenOff {
			t.Fatalf("shared token got %d %q", status, body)
		}
	}
	if r.limiter.blocked("127.0.0.1") {
		t.Error("the shared token counted as wrong guesses")
	}
}
