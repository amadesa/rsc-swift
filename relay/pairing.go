package main

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base32"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Pairing a device with a code, shown by `rsc-relay pair` or made by a
// device that's already paired (POST /v1/pairings):
//
//	ABCD-EFGH-JKMN-PQRS
//	└secret─┘ └─key──┘
//
// The first half is a one-time secret only the relay knows. The second half
// is the start of the relay's key fingerprint, so the app checks that it's
// talking to this relay before it sends anything: someone standing in for
// the relay on the network never sees the secret. POST /v1/pair with the
// secret then gives the device its own token.

const (
	pairingFile     = "pairing.json"
	pairingLifetime = 10 * time.Minute
	// each half: 8 characters of base32, 40 bits
	codeHalf = 8
)

// Crockford's base32: no I, L, O or U; those typed anyway are read as the
// digits they look like (normalizeCode)
var codeEncoding = base32.NewEncoding("0123456789ABCDEFGHJKMNPQRSTVWXYZ").WithPadding(base32.NoPadding)

type pendingPairing struct {
	SecretHash string    `json:"secret_sha256"`
	Name       string    `json:"name"`
	Expires    time.Time `json:"expires"`
}

type pairings struct {
	path string
	mu   sync.Mutex
}

func openPairings(dir string) *pairings {
	return &pairings{path: filepath.Join(dir, pairingFile)}
}

// create starts a pairing for a device called name and returns its code.
// Only one is pending at a time; a new one replaces it.
func (p *pairings) create(name string, pin string) (string, time.Time, error) {
	p.mu.Lock()
	defer p.mu.Unlock()

	secret := make([]byte, 5)
	if _, err := rand.Read(secret); err != nil {
		return "", time.Time{}, err
	}
	secretText := codeEncoding.EncodeToString(secret)

	pending := pendingPairing{
		SecretHash: hashToken(secretText),
		Name:       cleanName(name),
		Expires:    time.Now().Add(pairingLifetime).UTC().Truncate(time.Second),
	}
	data, err := json.Marshal(pending)
	if err != nil {
		return "", time.Time{}, err
	}
	if err := os.MkdirAll(filepath.Dir(p.path), 0o700); err != nil {
		return "", time.Time{}, err
	}
	if err := os.WriteFile(p.path, data, 0o600); err != nil {
		return "", time.Time{}, err
	}

	return formatCode(secretText + pinCode(pin)), pending.Expires, nil
}

// take uses up the pending pairing if secret matches, returning the name it
// was made for.
func (p *pairings) take(secret string) (string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()

	data, err := os.ReadFile(p.path)
	if errors.Is(err, os.ErrNotExist) {
		return "", errors.New("no pairing is waiting: make a code first")
	} else if err != nil {
		return "", err
	}

	var pending pendingPairing
	if err := json.Unmarshal(data, &pending); err != nil {
		return "", err
	}
	if time.Now().After(pending.Expires) {
		os.Remove(p.path)
		return "", errors.New("the pairing code expired: make a new one")
	}
	if subtle.ConstantTimeCompare([]byte(hashToken(normalizeCode(secret))), []byte(pending.SecretHash)) != 1 {
		return "", errWrongCode
	}

	os.Remove(p.path)
	return pending.Name, nil
}

var errWrongCode = errors.New("wrong pairing code")

// pinCode is the start of the key fingerprint, as it appears in a code.
func pinCode(pin string) string {
	sum := sha256.Sum256([]byte(pin))
	return codeEncoding.EncodeToString(sum[:5])
}

func formatCode(code string) string {
	var parts []string
	for len(code) > 4 {
		parts = append(parts, code[:4])
		code = code[4:]
	}
	return strings.Join(append(parts, code), "-")
}

func normalizeCode(code string) string {
	return strings.Map(func(r rune) rune {
		if r >= 'a' && r <= 'z' {
			r = r - 'a' + 'A'
		}
		switch r {
		case '-', ' ':
			return -1
		case 'O':
			return '0'
		case 'I', 'L':
			return '1'
		}
		return r
	}, code)
}

// pair answers POST /v1/pair {"secret": "ABCDEFGH", "name": "..."} with the
// device's own token. No token needed; wrong secrets count against the
// address like wrong tokens.
func (r *relay) pair(w http.ResponseWriter, req *http.Request) {
	address := remoteAddress(req)
	if r.limiter.blocked(address) {
		http.Error(w, "too many wrong codes, try again later", http.StatusTooManyRequests)
		return
	}
	if r.pairings == nil || r.devices == nil || r.info == nil {
		http.Error(w, "this relay can't pair devices", http.StatusNotFound)
		return
	}

	var request struct {
		Secret string `json:"secret"`
		Name   string `json:"name"`
	}
	if err := json.NewDecoder(io.LimitReader(req.Body, 1024)).Decode(&request); err != nil {
		http.Error(w, `expected {"secret": ..., "name": ...}`, http.StatusBadRequest)
		return
	}

	invited, err := r.pairings.take(request.Secret)
	if errors.Is(err, errWrongCode) {
		r.limiter.fail(address)
		http.Error(w, err.Error(), http.StatusForbidden)
		return
	} else if err != nil {
		http.Error(w, err.Error(), http.StatusGone)
		return
	}

	name := invited
	if strings.TrimSpace(request.Name) != "" {
		name = request.Name
	}
	d, token, err := r.devices.add(name)
	if err != nil {
		http.Error(w, "couldn't save the device", http.StatusInternalServerError)
		return
	}
	log.Printf("paired %s (%s)", d.Name, d.ID)

	info := r.info()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"token": token, "device_id": d.ID, "name": info.Name,
		"pin": info.Pin, "endpoints": info.Endpoints,
	})
}

// key answers GET /v1/key with the key fingerprint, which is public (it's
// in the Bonjour announcement too). An app pairing through a proxy such as
// Tailscale Funnel, where the TLS handshake shows the proxy's certificate,
// checks it against the code before sending the secret.
func (r *relay) key(w http.ResponseWriter, _ *http.Request) {
	if r.info == nil {
		http.Error(w, "this relay has no key (-tls-listen is off)", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"pin": r.info().Pin})
}

// invite answers POST /v1/pairings {"name": "..."} from a paired device
// with a code for another one, e.g. the iPhone pairing the Mac.
func (r *relay) invite(w http.ResponseWriter, req *http.Request) {
	if r.pairings == nil || r.info == nil {
		http.Error(w, "this relay can't pair devices", http.StatusNotFound)
		return
	}

	var request struct {
		Name string `json:"name"`
	}
	json.NewDecoder(io.LimitReader(req.Body, 1024)).Decode(&request)

	code, expires, err := r.pairings.create(request.Name, r.info().Pin)
	if err != nil {
		http.Error(w, "couldn't make a code", http.StatusInternalServerError)
		return
	}
	log.Printf("%s: made a pairing code for %q", clientName(req), cleanName(request.Name))

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(map[string]any{"code": code, "expires": expires})
}

// printPairing is `rsc-relay pair [NAME]`.
func printPairing(o options, name string) {
	id, err := loadOrCreateIdentity(o.data)
	if err != nil {
		log.Fatalf("identity: %v", err)
	}
	if name == "" {
		name = "device"
	}

	code, expires, err := openPairings(o.data).create(name, id.pin)
	if err != nil {
		log.Fatal(err)
	}

	fmt.Printf("Pairing code for %s (works once, until %s):\n\n    %s\n\n",
		cleanName(name), expires.Local().Format("15:04"), code)
	fmt.Println("In RSC on the iPhone: Accounts, Relay, then pick this relay or type one of:")
	for _, e := range endpoints(listenPort(o.tlsListen), o.localAddresses, o.advertise) {
		if e.Kind == "lan" {
			fmt.Printf("    %s\n", strings.TrimPrefix(e.URL, "https://"))
		}
	}
}
