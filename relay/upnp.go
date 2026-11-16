package main

import (
	"bytes"
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// UPnP port mapping: asks the router (UPnP IGD, which eero and most home
// routers support) to forward the relay's HTTPS port from the internet, and
// learns the public address to offer apps. Off unless -upnp is given: it
// opens a port on the router. The mapping is renewed while the relay runs
// and removed when it stops cleanly.

const (
	upnpLease   = time.Hour
	upnpRenew   = 30 * time.Minute
	upnpTimeout = 3 * time.Second
)

var upnpServices = []string{
	"urn:schemas-upnp-org:service:WANIPConnection:2",
	"urn:schemas-upnp-org:service:WANIPConnection:1",
	"urn:schemas-upnp-org:service:WANPPPConnection:1",
}

type gateway struct {
	controlURL string
	service    string
	localIP    net.IP // our address on the router's network
}

// discoverGateway finds the router's port-mapping service with SSDP.
func discoverGateway() (*gateway, error) {
	conn, err := net.ListenUDP("udp4", nil)
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	ssdp := &net.UDPAddr{IP: net.IPv4(239, 255, 255, 250), Port: 1900}
	for _, target := range []string{"urn:schemas-upnp-org:device:InternetGatewayDevice:2", "urn:schemas-upnp-org:device:InternetGatewayDevice:1"} {
		search := "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: " + target + "\r\n\r\n"
		conn.WriteToUDP([]byte(search), ssdp)
	}

	conn.SetReadDeadline(time.Now().Add(upnpTimeout))
	buf := make([]byte, 4096)
	seen := map[string]bool{}
	for {
		n, _, err := conn.ReadFromUDP(buf)
		if err != nil {
			return nil, errors.New("no UPnP router answered (is UPnP on in the router's settings?)")
		}
		location := headerValue(string(buf[:n]), "LOCATION")
		if location == "" || seen[location] {
			continue
		}
		seen[location] = true
		if gw, err := describeGateway(location); err == nil {
			return gw, nil
		}
	}
}

func headerValue(response, name string) string {
	for _, line := range strings.Split(response, "\r\n") {
		if key, value, ok := strings.Cut(line, ":"); ok && strings.EqualFold(strings.TrimSpace(key), name) {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

// describeGateway reads the router's device description for the control
// URL of its WAN connection service.
func describeGateway(location string) (*gateway, error) {
	base, err := url.Parse(location)
	if err != nil {
		return nil, err
	}

	client := &http.Client{Timeout: upnpTimeout}
	resp, err := client.Get(location)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}

	// services can be nested at any depth in the device tree
	decoder := xml.NewDecoder(bytes.NewReader(body))
	var service, control string
	for {
		token, err := decoder.Token()
		if err != nil {
			break
		}
		start, ok := token.(xml.StartElement)
		if !ok || start.Name.Local != "service" {
			continue
		}
		var s struct {
			ServiceType string `xml:"serviceType"`
			ControlURL  string `xml:"controlURL"`
		}
		if decoder.DecodeElement(&s, &start) != nil {
			continue
		}
		for _, wanted := range upnpServices {
			if s.ServiceType == wanted && (service == "" || preferred(wanted, service)) {
				service, control = s.ServiceType, s.ControlURL
			}
		}
	}
	if service == "" {
		return nil, errors.New("not an internet gateway")
	}

	controlURL, err := base.Parse(control)
	if err != nil {
		return nil, err
	}

	// the address the router sees us at
	conn, err := net.Dial("udp4", controlURL.Host)
	if err != nil {
		return nil, err
	}
	localIP := conn.LocalAddr().(*net.UDPAddr).IP
	conn.Close()

	return &gateway{controlURL: controlURL.String(), service: service, localIP: localIP}, nil
}

func preferred(candidate, current string) bool {
	rank := func(s string) int {
		for i, wanted := range upnpServices {
			if s == wanted {
				return i
			}
		}
		return len(upnpServices)
	}
	return rank(candidate) < rank(current)
}

func (g *gateway) call(action string, args [][2]string) (map[string]string, error) {
	var body strings.Builder
	body.WriteString(`<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>`)
	fmt.Fprintf(&body, `<u:%s xmlns:u="%s">`, action, g.service)
	for _, arg := range args {
		fmt.Fprintf(&body, "<%s>", arg[0])
		xml.EscapeText(&body, []byte(arg[1]))
		fmt.Fprintf(&body, "</%s>", arg[0])
	}
	fmt.Fprintf(&body, "</u:%s></s:Body></s:Envelope>", action)

	ctx, cancel := context.WithTimeout(context.Background(), upnpTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "POST", g.controlURL, strings.NewReader(body.String()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", `text/xml; charset="utf-8"`)
	req.Header.Set("SOAPAction", fmt.Sprintf(`"%s#%s"`, g.service, action))

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))

	// the reply's elements, flattened: <NewExternalIPAddress>, <errorCode>...
	values := map[string]string{}
	decoder := xml.NewDecoder(bytes.NewReader(data))
	var current string
	for {
		token, err := decoder.Token()
		if err != nil {
			break
		}
		switch t := token.(type) {
		case xml.StartElement:
			current = t.Name.Local
		case xml.CharData:
			if text := strings.TrimSpace(string(t)); text != "" && current != "" {
				values[current] = text
			}
		case xml.EndElement:
			current = ""
		}
	}

	if resp.StatusCode != http.StatusOK {
		return values, fmt.Errorf("%s refused: %s %s", action, values["errorCode"], values["errorDescription"])
	}
	return values, nil
}

func (g *gateway) externalIP() (net.IP, error) {
	values, err := g.call("GetExternalIPAddress", nil)
	if err != nil {
		return nil, err
	}
	ip := net.ParseIP(values["NewExternalIPAddress"])
	if ip == nil {
		return nil, errors.New("the router didn't say its public address")
	}
	return ip, nil
}

func (g *gateway) addMapping(port int, lease time.Duration) error {
	_, err := g.call("AddPortMapping", [][2]string{
		{"NewRemoteHost", ""},
		{"NewExternalPort", strconv.Itoa(port)},
		{"NewProtocol", "TCP"},
		{"NewInternalPort", strconv.Itoa(port)},
		{"NewInternalClient", g.localIP.String()},
		{"NewEnabled", "1"},
		{"NewPortMappingDescription", "rsc-relay"},
		{"NewLeaseDuration", strconv.Itoa(int(lease.Seconds()))},
	})
	return err
}

func (g *gateway) deleteMapping(port int) error {
	_, err := g.call("DeletePortMapping", [][2]string{
		{"NewRemoteHost", ""},
		{"NewExternalPort", strconv.Itoa(port)},
		{"NewProtocol", "TCP"},
	})
	return err
}

// portMapper keeps the router forwarding the port, and knows the public
// address while it does.
type portMapper struct {
	port int

	mu     sync.Mutex
	public string // "https://203.0.113.5:8443", "" when not mapped
	gw     *gateway
}

func (p *portMapper) publicURL() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.public
}

// run maps the port and renews it until the relay stops.
func (p *portMapper) run() {
	for {
		p.refresh()
		time.Sleep(upnpRenew)
	}
}

func (p *portMapper) refresh() {
	gw, err := discoverGateway()
	if err == nil {
		err = gw.addMapping(p.port, upnpLease)
	}
	var ip net.IP
	if err == nil {
		ip, err = gw.externalIP()
	}

	p.mu.Lock()
	defer p.mu.Unlock()
	if err != nil {
		if p.public != "" || p.gw == nil {
			log.Printf("UPnP: couldn't forward port %d: %v", p.port, err)
		}
		p.public = ""
		return
	}

	public := "https://" + net.JoinHostPort(ip.String(), strconv.Itoa(p.port))
	if public != p.public {
		log.Printf("UPnP: the router forwards %s to this machine (%s)", public, gw.localIP)
		if ip.IsPrivate() || tailnetV4.Contains(ip) {
			log.Printf("UPnP: but %s isn't a public address: another router or the ISP is in front (double NAT), so this won't be reachable from outside", ip)
		}
	}
	p.public, p.gw = public, gw
}

// stop removes the mapping, so the port isn't left open.
func (p *portMapper) stop() {
	p.mu.Lock()
	gw := p.gw
	p.mu.Unlock()
	if gw != nil {
		if err := gw.deleteMapping(p.port); err == nil {
			log.Printf("UPnP: removed the port forward")
		}
	}
}

// checkUPnP is `rsc-relay upnp`: what the router says, changing nothing.
func checkUPnP() {
	gw, err := discoverGateway()
	if err != nil {
		fmt.Println(err)
		return
	}
	fmt.Printf("router: %s (%s)\nthis machine on its network: %s\n", gw.controlURL, gw.service, gw.localIP)
	if ip, err := gw.externalIP(); err != nil {
		fmt.Println("public address:", err)
	} else {
		fmt.Println("public address:", ip)
		if ip.IsPrivate() || tailnetV4.Contains(ip) {
			fmt.Println("  that isn't public: there's another router or ISP NAT in front (double NAT)")
		}
	}
}
