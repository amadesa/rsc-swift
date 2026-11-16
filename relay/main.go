// Command rsc-relay lets clients that can only make HTTPS requests, such as
// Apple Watch apps (watchOS blocks other networking, see TN3135), play on a
// RuneScape Classic server. It holds the game's TCP connection and passes
// bytes back and forth over plain HTTP, meant to sit behind TLS such as
// Tailscale Funnel, and over its own HTTPS port.
//
//	rsc-relay [-data dir] [-listen 127.0.0.1:8737] [-tls-listen :8443]
//	          [-advertise address,...] [-allow host:port,...]
//	rsc-relay info                   the key fingerprint and addresses
//	rsc-relay pair [NAME]            a one-time code to pair a device
//	rsc-relay devices list|add NAME|remove ID
//	rsc-relay upnp                   what the router says about port forwarding
//
// Every flag can also be set in the environment as RSC_RELAY_<FLAG>
// (RSC_RELAY_TLS_LISTEN, ...), for containers.
//
// The HTTPS port uses a self-signed certificate for the relay's own key
// (identity.go). Apps pin that key, so any address that reaches the relay
// is safe to use: /v1/info lists them.
//
// API (all but /v1/health need "Authorization: Bearer <token>", either the
// shared token or a paired device's; clients name themselves in
// X-RSC-Client, such as "watch 0.2.0", for the log):
//
//	POST   /v1/sessions               {"host": "...", "port": 43596} -> {"id": "..."}
//	POST   /v1/sessions/{id}/send?at=N   body: bytes, N = stream offset of the first byte
//	GET    /v1/sessions/{id}/recv?from=N&wait=ms
//	                                  -> bytes from offset N (also acknowledges
//	                                     everything before N); X-Offset: N
//	DELETE /v1/sessions/{id}
//	GET    /v1/health
//	GET    /v1/info                  -> {"pin": "sha256/...", "endpoints": [{"url", "kind"}]}
//	GET    /v1/key                   -> {"pin": "sha256/..."} (no token needed: it's public)
//	POST   /v1/pair                  {"secret", "name"} -> {"token", "pin", "endpoints"} (no token needed)
//	POST   /v1/pairings              {"name"} -> {"code"}: a code for another device
//	GET    /v1/check[?host=...&port=N] -> whether the relay can reach the
//	                                     game server (or every allowed one)
//
// Every response carries X-RSC-Relay: <version>, and every refused request
// is logged with the reason, so a client that can't connect either shows up
// in the log or never reached the relay at all.

// Offsets make every request safe to retry: a repeated send is ignored and a
// lost recv response can be fetched again.
package main

import (
	"crypto/rand"
	"crypto/subtle"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// the worlds the client ships with. anything else has to be allowed
// explicitly, so the relay can't be used as an open proxy
const defaultAllow = "game.openrsc.com:43596,game.openrsc.com:43235,game.openrsc.com:43593,192.3.118.9:43594"

const (
	maxRecvWait   = 20 * time.Second
	maxSendBytes  = 64 << 10
	maxRecvBytes  = 64 << 10
	maxBuffered   = 4 << 20 // unacknowledged bytes from the server
	dialTimeout   = 10 * time.Second
	maxSessions   = 16
	sessionIDSize = 16
)

type options struct {
	data      string
	listen    string
	tlsListen string
	advertise []string
	// list this machine's own addresses in /v1/info (off in a bridged
	// container, where they're the container's)
	localAddresses bool
	// forward the HTTPS port on the router with UPnP
	upnp bool
	// announce the relay on the home network with Bonjour
	mdns bool
	// accept the shared token, besides paired devices' own
	sharedToken bool
	tokenFile   string
	allow       string
	idle        time.Duration
}

func parseOptions(args []string) options {
	flags := flag.NewFlagSet("rsc-relay", flag.ExitOnError)
	var o options
	var advertise string

	flags.StringVar(&o.data, "data", env("DATA", defaultDataDir()), "directory for the key, token and paired devices")
	flags.StringVar(&o.listen, "listen", env("LISTEN", "127.0.0.1:8737"), "plain HTTP address, for Tailscale Funnel or another TLS proxy (empty to turn off)")
	flags.StringVar(&o.tlsListen, "tls-listen", env("TLS_LISTEN", ":8443"), "HTTPS address with the relay's own key (empty to turn off)")
	flags.StringVar(&advertise, "advertise", env("ADVERTISE", ""), "comma-separated extra addresses apps may use: public IP, WireGuard address, Funnel URL...")
	flags.BoolVar(&o.localAddresses, "local-addresses", env("LOCAL_ADDRESSES", "true") != "false", "offer this machine's own addresses to apps, besides -advertise")
	flags.BoolVar(&o.upnp, "upnp", env("UPNP", "false") == "true", "ask the router (UPnP) to forward the HTTPS port from the internet, and offer the public address")
	flags.BoolVar(&o.mdns, "bonjour", env("BONJOUR", "true") != "false", "announce the relay on the home network (Bonjour), for pairing")
	flags.BoolVar(&o.sharedToken, "shared-token", env("SHARED_TOKEN", "true") != "false", "accept the shared token; false once every device is paired")
	flags.StringVar(&o.tokenFile, "token-file", env("TOKEN_FILE", ""), "file holding the shared access token (default <data>/token, created if missing)")
	flags.StringVar(&o.allow, "allow", env("ALLOW", defaultAllow), "comma-separated host:port game servers clients may connect to")
	flags.DurationVar(&o.idle, "idle", envDuration("IDLE", 60*time.Second), "close sessions the client hasn't polled for this long")
	flags.Parse(args)

	for _, address := range strings.Split(advertise, ",") {
		if address = strings.TrimSpace(address); address != "" {
			o.advertise = append(o.advertise, address)
		}
	}
	if o.tokenFile == "" {
		o.tokenFile = filepath.Join(o.data, "token")
	}
	return o
}

func main() {
	args := os.Args[1:]
	command := ""
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		command, args = args[0], args[1:]
	}

	switch command {
	case "":
		serve(parseOptions(args))
	case "info":
		printInfo(parseOptions(args))
	case "devices":
		manageDevices(args)
	case "pair":
		name := ""
		if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
			name, args = args[0], args[1:]
		}
		printPairing(parseOptions(args), name)
	case "upnp":
		checkUPnP()
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q (commands: info, pair, devices, upnp)\n", command)
		os.Exit(2)
	}
}

func serve(o options) {
	token, err := loadOrCreateToken(o.tokenFile)
	if err != nil {
		log.Fatalf("token: %v", err)
	}
	devices, err := openDevices(o.data)
	if err != nil {
		log.Fatalf("devices: %v", err)
	}

	relay := newRelay(token, parseAllow(o.allow), o.idle)
	relay.devices = devices
	relay.sharedOff = !o.sharedToken
	go relay.reapIdle()

	log.Printf("rsc-relay %s, allowing %s", version, o.allow)
	if o.sharedToken {
		log.Printf("data in %s (shared token in %s)", o.data, o.tokenFile)
	} else {
		log.Printf("data in %s (shared token off: only paired devices)", o.data)
	}

	failed := make(chan error, 2)
	servers := 0

	if o.listen != "" {
		server := &http.Server{
			Addr:              o.listen,
			Handler:           relay.routes(),
			ReadHeaderTimeout: 10 * time.Second,
		}
		log.Printf("listening on http://%s", o.listen)
		go func() { failed <- server.ListenAndServe() }()
		servers++
	}

	if o.tlsListen != "" {
		id, err := loadOrCreateIdentity(o.data)
		if err != nil {
			log.Fatalf("identity: %v", err)
		}
		certificate, err := id.certificate(certificateIPs(o.advertise, o.localAddresses))
		if err != nil {
			log.Fatalf("certificate: %v", err)
		}

		port := listenPort(o.tlsListen)
		relay.pairings = openPairings(o.data)

		var mapper *portMapper
		if o.upnp && port > 0 {
			mapper = &portMapper{port: port}
			go mapper.run()
			stopOnSignal(mapper.stop)
		}

		relay.info = func() relayInfo {
			list := endpoints(port, o.localAddresses, o.advertise)
			if mapper != nil {
				if public := mapper.publicURL(); public != "" {
					list = append(list, endpoint{URL: public, Kind: "public"})
				}
			}
			return relayInfo{Version: version, Name: hostName(), Pin: id.pin, Endpoints: list}
		}

		if o.mdns && port > 0 {
			go newMDNS(hostName(), port, id.pin).run()
		}

		server := &http.Server{
			Addr:              o.tlsListen,
			Handler:           relay.routes(),
			ReadHeaderTimeout: 10 * time.Second,
			IdleTimeout:       2 * time.Minute,
			TLSConfig: &tls.Config{
				Certificates: []tls.Certificate{certificate},
				MinVersion:   tls.VersionTLS12,
			},
			// apps try several addresses at once and hang up on the slower
			// ones, which ends their handshakes early: not worth a line
			ErrorLog: log.New(quietHandshakes{}, "", log.LstdFlags),
		}
		log.Printf("listening on https://%s, key %s", o.tlsListen, id.pin)
		for _, e := range relay.info().Endpoints {
			log.Printf("  reachable at %s (%s)", e.URL, e.Kind)
		}
		go func() { failed <- server.ListenAndServeTLS("", "") }()
		servers++
	}

	if servers == 0 {
		log.Fatal("nothing to listen on: -listen and -tls-listen are both empty")
	}
	log.Fatal(<-failed)
}

// printInfo shows what pairing an app needs, without starting the relay.
func printInfo(o options) {
	id, err := loadOrCreateIdentity(o.data)
	if err != nil {
		log.Fatalf("identity: %v", err)
	}
	fmt.Printf("key: %s\n", id.pin)
	if o.tlsListen == "" {
		return
	}
	for _, e := range endpoints(listenPort(o.tlsListen), o.localAddresses, o.advertise) {
		fmt.Printf("%-10s %s\n", e.Kind, e.URL)
	}
}

func manageDevices(args []string) {
	usage := "usage: rsc-relay devices [-data dir] list | add NAME | remove ID"
	flags := flag.NewFlagSet("devices", flag.ExitOnError)
	data := flags.String("data", env("DATA", defaultDataDir()), "data directory")
	flags.Parse(args)
	args = flags.Args()

	store, err := openDevices(*data)
	if err != nil {
		log.Fatal(err)
	}

	switch {
	case len(args) == 0 || args[0] == "list":
		devices := store.list()
		if len(devices) == 0 {
			fmt.Println("no paired devices")
		}
		for _, d := range devices {
			fmt.Printf("%s  %-24s paired %s\n", d.ID, d.Name, d.Created.Local().Format("2006-01-02 15:04"))
		}
	case args[0] == "add" && len(args) >= 2:
		d, token, err := store.add(strings.Join(args[1:], " "))
		if err != nil {
			log.Fatal(err)
		}
		fmt.Printf("paired %s (%s). Its token, shown only now:\n%s\n", d.Name, d.ID, token)
	case args[0] == "remove" && len(args) == 2:
		d, err := store.remove(args[1])
		if err != nil {
			log.Fatal(err)
		}
		fmt.Printf("removed %s (%s)\n", d.Name, d.ID)
	default:
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
}

func env(name, fallback string) string {
	if value, ok := os.LookupEnv("RSC_RELAY_" + name); ok {
		return value
	}
	return fallback
}

func envDuration(name string, fallback time.Duration) time.Duration {
	if d, err := time.ParseDuration(env(name, "")); err == nil {
		return d
	}
	return fallback
}

func defaultDataDir() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		dir = "."
	}
	return filepath.Join(dir, "rsc-relay")
}

// quietHandshakes drops "TLS handshake error ... EOF" lines from the HTTPS
// server's log and passes the rest on.
type quietHandshakes struct{}

func (quietHandshakes) Write(line []byte) (int, error) {
	text := string(line)
	if strings.Contains(text, "TLS handshake error") &&
		(strings.HasSuffix(strings.TrimSpace(text), ": EOF") || strings.Contains(text, "connection reset")) {
		return len(line), nil
	}
	return log.Writer().Write(line)
}

// arrivedVia names the way a request reached the relay, for the log:
// through Funnel (or another proxy on this machine), or straight to the
// relay's own port on one of its addresses.
func arrivedVia(req *http.Request) string {
	local, ok := req.Context().Value(http.LocalAddrContextKey).(net.Addr)
	if !ok {
		return "unknown"
	}
	host, _, err := net.SplitHostPort(local.String())
	if err != nil {
		return local.String()
	}
	ip := net.ParseIP(host)
	if ip == nil || ip.IsLoopback() {
		return "Funnel or a local proxy"
	}
	kind := addressKind(ip)
	names := map[string]string{"lan": "home network", "tailscale": "Tailscale", "ipv6": "IPv6", "advertised": "public address"}
	if name, ok := names[kind]; ok {
		return name + " " + local.String()
	}
	return local.String()
}

func listenPort(address string) int {
	_, port, err := net.SplitHostPort(address)
	if err != nil {
		return 0
	}
	n, _ := strconv.Atoi(port)
	return n
}

// stopOnSignal runs cleanup (removing the router's port forward) when the
// relay is stopped, then exits.
func stopOnSignal(cleanup func()) {
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-signals
		cleanup()
		os.Exit(0)
	}()
}

func hostName() string {
	name, _ := os.Hostname()
	return strings.TrimSuffix(name, ".local")
}

// loadOrCreateToken reads the token, or generates one on first run so there
// is never a relay without one.
func loadOrCreateToken(path string) (string, error) {
	if data, err := os.ReadFile(path); err == nil {
		token := strings.TrimSpace(string(data))
		if len(token) < 16 {
			return "", fmt.Errorf("%s holds a token shorter than 16 characters", path)
		}
		return token, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}

	token := randomHex(24)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", err
	}
	if err := os.WriteFile(path, []byte(token+"\n"), 0o600); err != nil {
		return "", err
	}
	log.Printf("created a new access token in %s", path)
	return token, nil
}

func randomHex(bytes int) string {
	buf := make([]byte, bytes)
	if _, err := rand.Read(buf); err != nil {
		panic(err)
	}
	return hex.EncodeToString(buf)
}

func parseAllow(list string) map[string]bool {
	allowed := map[string]bool{}
	for _, entry := range strings.Split(list, ",") {
		if entry = strings.TrimSpace(strings.ToLower(entry)); entry != "" {
			allowed[entry] = true
		}
	}
	return allowed
}

type relay struct {
	token   string
	allowed map[string]bool
	idle    time.Duration
	// paired devices' tokens, besides the shared one (nil in tests)
	devices *deviceStore
	// the shared token is refused, so only paired devices get in
	sharedOff bool
	// what /v1/info says, once the HTTPS listener is set up
	info func() relayInfo
	// codes for pairing devices
	pairings *pairings
	limiter  limiter

	mu       sync.Mutex
	sessions map[string]*session

	failures failureLog
}

func newRelay(token string, allowed map[string]bool, idle time.Duration) *relay {
	return &relay{token: token, allowed: allowed, idle: idle, sessions: map[string]*session{}}
}

func (r *relay) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/health", func(w http.ResponseWriter, _ *http.Request) {
		io.WriteString(w, "ok\n")
	})
	mux.HandleFunc("GET /v1/check", r.authed(r.check))
	mux.HandleFunc("GET /v1/info", r.authed(r.describe))
	mux.HandleFunc("GET /v1/key", r.key)
	mux.HandleFunc("POST /v1/pair", r.pair)
	mux.HandleFunc("POST /v1/pairings", r.authed(r.invite))
	mux.HandleFunc("POST /v1/sessions", r.authed(r.create))
	mux.HandleFunc("POST /v1/sessions/{id}/send", r.authed(r.withSession(r.send)))
	mux.HandleFunc("GET /v1/sessions/{id}/recv", r.authed(r.withSession(r.recv)))
	mux.HandleFunc("DELETE /v1/sessions/{id}", r.authed(r.withSession(r.remove)))
	return r.logged(mux)
}

func (r *relay) sessionCount() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.sessions)
}

func (r *relay) authed(next http.HandlerFunc) http.HandlerFunc {
	want := []byte("Bearer " + r.token)
	return func(w http.ResponseWriter, req *http.Request) {
		address := remoteAddress(req)
		if r.limiter.blocked(address) {
			http.Error(w, "too many wrong tokens, try again later", http.StatusTooManyRequests)
			return
		}

		got := req.Header.Get("Authorization")
		if subtle.ConstantTimeCompare([]byte(got), want) == 1 {
			if r.sharedOff {
				// not a guess, so it doesn't count against the address
				http.Error(w, sharedTokenOff, http.StatusUnauthorized)
				return
			}
			next(w, req)
			return
		}

		if r.devices != nil && strings.HasPrefix(got, "Bearer ") {
			if d, ok := r.devices.lookup(strings.TrimPrefix(got, "Bearer ")); ok {
				// the log names the paired device too, with its id for `devices remove`
				req.Header.Set("X-RSC-Client", clientName(req)+" ["+d.Name+" "+d.ID+"]")
				next(w, req)
				return
			}
		}

		r.limiter.fail(address)
		http.Error(w, "unauthorized", http.StatusUnauthorized)
	}
}

const sharedTokenOff = "the shared token is turned off; pair this device"

// relayInfo is /v1/info: how to reach and recognise this relay.
type relayInfo struct {
	Version   string     `json:"version"`
	Name      string     `json:"name"`
	Pin       string     `json:"pin"`
	Endpoints []endpoint `json:"endpoints"`
}

func (r *relay) describe(w http.ResponseWriter, _ *http.Request) {
	if r.info == nil {
		http.Error(w, "this relay has no HTTPS port (-tls-listen)", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(r.info())
}

func (r *relay) withSession(next func(http.ResponseWriter, *http.Request, *session)) http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
		r.mu.Lock()
		s := r.sessions[req.PathValue("id")]
		r.mu.Unlock()

		if s == nil {
			http.Error(w, "no such session", http.StatusNotFound)
			return
		}
		s.touch()
		next(w, req, s)
	}
}

func (r *relay) create(w http.ResponseWriter, req *http.Request) {
	var target struct {
		Host string `json:"host"`
		Port int    `json:"port"`
	}
	if err := json.NewDecoder(io.LimitReader(req.Body, 1024)).Decode(&target); err != nil {
		http.Error(w, "expected {\"host\": ..., \"port\": ...}", http.StatusBadRequest)
		return
	}

	address := net.JoinHostPort(strings.ToLower(target.Host), strconv.Itoa(target.Port))
	if !r.allowed[address] {
		http.Error(w, address+" isn't in this relay's allow list", http.StatusForbidden)
		return
	}

	r.mu.Lock()
	full := len(r.sessions) >= maxSessions
	r.mu.Unlock()
	if full {
		http.Error(w, "too many sessions", http.StatusServiceUnavailable)
		return
	}

	conn, err := net.DialTimeout("tcp", address, dialTimeout)
	if err != nil {
		http.Error(w, "couldn't reach "+address+": "+dialError(err), http.StatusBadGateway)
		return
	}
	if tcp, ok := conn.(*net.TCPConn); ok {
		tcp.SetNoDelay(true)
	}

	s := newSession(randomHex(sessionIDSize), conn, clientName(req), address)
	r.mu.Lock()
	r.sessions[s.id] = s
	r.mu.Unlock()
	go s.readLoop()

	log.Printf("%s: session %s… opened to %s, via %s", s.client, s.id[:6], address, arrivedVia(req))

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(map[string]string{"id": s.id})
}

func (r *relay) send(w http.ResponseWriter, req *http.Request, s *session) {
	at, err := strconv.ParseInt(req.URL.Query().Get("at"), 10, 64)
	if err != nil || at < 0 {
		http.Error(w, "missing or bad ?at= offset", http.StatusBadRequest)
		return
	}

	data, err := io.ReadAll(io.LimitReader(req.Body, maxSendBytes+1))
	if err != nil {
		http.Error(w, "couldn't read body", http.StatusBadRequest)
		return
	}
	if len(data) > maxSendBytes {
		http.Error(w, "body too large", http.StatusRequestEntityTooLarge)
		return
	}

	switch err := s.write(at, data); {
	case errors.Is(err, errGap):
		http.Error(w, err.Error(), http.StatusConflict)
	case errors.Is(err, errClosed):
		http.Error(w, "connection closed", http.StatusGone)
	case err != nil:
		http.Error(w, "write failed", http.StatusBadGateway)
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}

func (r *relay) recv(w http.ResponseWriter, req *http.Request, s *session) {
	from, err := strconv.ParseInt(req.URL.Query().Get("from"), 10, 64)
	if err != nil || from < 0 {
		http.Error(w, "missing or bad ?from= offset", http.StatusBadRequest)
		return
	}

	wait := maxRecvWait
	if ms, err := strconv.Atoi(req.URL.Query().Get("wait")); err == nil && ms >= 0 {
		wait = min(time.Duration(ms)*time.Millisecond, maxRecvWait)
	}

	data, closed, err := s.read(req.Context(), from, wait)
	switch {
	case errors.Is(err, errGap):
		http.Error(w, err.Error(), http.StatusConflict)
		return
	case err != nil:
		return // the client went away
	case closed && len(data) == 0:
		http.Error(w, "connection closed", http.StatusGone)
		return
	}

	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-Offset", strconv.FormatInt(from, 10))
	w.Write(data)
}

func (r *relay) remove(w http.ResponseWriter, _ *http.Request, s *session) {
	r.close(s, "closed by client")
	w.WriteHeader(http.StatusNoContent)
}

func (r *relay) close(s *session, reason string) {
	r.mu.Lock()
	_, present := r.sessions[s.id]
	delete(r.sessions, s.id)
	r.mu.Unlock()

	if present {
		s.conn.Close()
		log.Printf("%s: session %s… %s", s.client, s.id[:6], s.summary(reason))
	}
}

// reapIdle closes sessions whose client stopped polling, e.g. a watch that
// went to sleep, so their game connections don't linger.
func (r *relay) reapIdle() {
	for range time.Tick(5 * time.Second) {
		r.mu.Lock()
		var stale []*session
		for _, s := range r.sessions {
			if s.idleFor() > r.idle {
				stale = append(stale, s)
			}
		}
		r.mu.Unlock()

		for _, s := range stale {
			r.close(s, "closed after going idle")
		}
	}
}
