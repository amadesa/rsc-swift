package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func pairingRelay(t *testing.T) (*client, *relay, string) {
	t.Helper()
	dir := t.TempDir()
	c, r := newTestRelay(t, "", time.Minute)

	devices, err := openDevices(dir)
	if err != nil {
		t.Fatal(err)
	}
	r.devices = devices
	r.pairings = openPairings(dir)
	r.info = func() relayInfo { return relayInfo{Version: version, Name: "test", Pin: "sha256/test-pin"} }
	return c, r, dir
}

func postJSON(t *testing.T, url string, body any, token string) (int, map[string]any) {
	t.Helper()
	data, _ := json.Marshal(body)
	req, _ := http.NewRequest("POST", url, bytes.NewReader(data))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func TestPairingCode(t *testing.T) {
	_, r, _ := pairingRelay(t)

	code, expires, err := r.pairings.create("Alex's iPhone", "sha256/test-pin")
	if err != nil {
		t.Fatal(err)
	}
	if parts := strings.Split(code, "-"); len(parts) != 4 || len(code) != 19 {
		t.Fatalf("code %q isn't XXXX-XXXX-XXXX-XXXX", code)
	}
	if time.Until(expires) > pairingLifetime {
		t.Errorf("expires too late: %v", expires)
	}

	// the second half identifies the relay's key
	if got := normalizeCode(code)[codeHalf:]; got != pinCode("sha256/test-pin") {
		t.Errorf("key half %q, want %q", got, pinCode("sha256/test-pin"))
	}

	// typed in lower case with O for 0 and I/L for 1 still matches
	if normalizeCode("o1il-ab") != "0111AB" {
		t.Errorf("normalizeCode: %q", normalizeCode("o1il-ab"))
	}
}

func TestPairing(t *testing.T) {
	c, r, dir := pairingRelay(t)

	code, _, err := r.pairings.create("Apple Watch", "sha256/test-pin")
	if err != nil {
		t.Fatal(err)
	}
	secret := strings.ToLower(normalizeCode(code)[:codeHalf])

	// the key is public, for checking the code through a proxy
	resp, err := http.Get(c.base + "/v1/key")
	if err != nil {
		t.Fatal(err)
	}
	var key map[string]string
	json.NewDecoder(resp.Body).Decode(&key)
	resp.Body.Close()
	if key["pin"] != "sha256/test-pin" {
		t.Fatalf("/v1/key said %v", key)
	}

	// a wrong secret is refused and counts against the address
	if status, _ := postJSON(t, c.base+"/v1/pair", map[string]string{"secret": "ZZZZZZZZ"}, ""); status != http.StatusForbidden {
		t.Fatalf("wrong secret got %d", status)
	}

	status, out := postJSON(t, c.base+"/v1/pair", map[string]string{"secret": secret}, "")
	if status != http.StatusOK {
		t.Fatalf("pairing got %d %v", status, out)
	}
	token, _ := out["token"].(string)
	if len(token) < 32 || out["pin"] != "sha256/test-pin" {
		t.Fatalf("pairing answer %v", out)
	}
	if d, ok := r.devices.lookup(token); !ok || d.Name != "Apple Watch" {
		t.Fatalf("paired device %+v, %v", d, ok)
	}

	// once only
	if status, _ := postJSON(t, c.base+"/v1/pair", map[string]string{"secret": secret}, ""); status != http.StatusGone {
		t.Fatalf("second use got %d", status)
	}
	if _, err := os.Stat(filepath.Join(dir, pairingFile)); !os.IsNotExist(err) {
		t.Error("the used pairing is still on disk")
	}

	// the paired device can invite another, with its own token
	status, out = postJSON(t, c.base+"/v1/pairings", map[string]string{"name": "Mac"}, token)
	if status != http.StatusCreated || out["code"] == nil {
		t.Fatalf("invite got %d %v", status, out)
	}
	if status, _ := postJSON(t, c.base+"/v1/pairings", map[string]string{"name": "Mac"}, ""); status != http.StatusUnauthorized {
		t.Fatalf("invite without a token got %d", status)
	}
}

func TestExpiredPairing(t *testing.T) {
	c, r, dir := pairingRelay(t)

	code, _, _ := r.pairings.create("old", "sha256/test-pin")
	pending := pendingPairing{}
	data, _ := os.ReadFile(filepath.Join(dir, pairingFile))
	json.Unmarshal(data, &pending)
	pending.Expires = time.Now().Add(-time.Minute)
	data, _ = json.Marshal(pending)
	os.WriteFile(filepath.Join(dir, pairingFile), data, 0o600)

	status, _ := postJSON(t, c.base+"/v1/pair", map[string]string{"secret": normalizeCode(code)[:codeHalf]}, "")
	if status != http.StatusGone {
		t.Fatalf("expired code got %d", status)
	}
}

// A Bonjour browser asking for _rsc-relay._tcp gets the service, its port,
// the key in TXT and the home network address.
func TestBonjourAnswers(t *testing.T) {
	m := newMDNS("11700", 8443, "sha256/test-pin")
	m.addrs = func() []net.IP { return []net.IP{net.IPv4(192, 168, 4, 52).To4()} }

	// a query as iOS sends it, with the question's name compressed to the
	// header for good measure
	query := []byte{0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0}
	query = append(query, encodeName(mdnsService)...)
	query = append(query, 0, typePTR, 0x80, classIN) // QU bit set
	questions, err := parseQuestions(query)
	if err != nil || len(questions) != 1 || !questions[0].unicast || questions[0].name != mdnsService {
		t.Fatalf("parsed %+v, %v", questions, err)
	}

	reply := m.response(questions[0].qtype, questions[0].name)
	if reply == nil {
		t.Fatal("no answer")
	}
	if answers := binary.BigEndian.Uint16(reply[6:8]); answers != 1 {
		t.Errorf("%d answers", answers)
	}
	for _, want := range [][]byte{[]byte("11700"), []byte("pin=sha256/test-pin"), {192, 168, 4, 52}, {0x20, 0xfb}} {
		if !bytes.Contains(reply, want) {
			t.Errorf("reply lacks %q", want)
		}
	}

	if m.response(typePTR, "_other._tcp.local.") != nil {
		t.Error("answered for another service")
	}

	// compressed names in questions
	msg := append([]byte{}, query...)
	pointer := []byte{0xc0, 12, 0, typeSRV, 0, classIN}
	msg[5] = 2
	msg = append(msg, pointer...)
	questions, err = parseQuestions(msg)
	if err != nil || len(questions) != 2 || questions[1].name != mdnsService {
		t.Fatalf("compressed question: %+v, %v", questions, err)
	}
}
