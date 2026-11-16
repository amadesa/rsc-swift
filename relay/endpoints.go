package main

import (
	"net"
	"net/url"
	"sort"
	"strconv"
	"strings"
)

// endpoint is one address apps can try to reach the relay at. Apps check
// the relay's pinned key on every one, so they're all equally safe to use.
type endpoint struct {
	URL string `json:"url"`
	// "lan", "ipv6", "tailscale" or "advertised" (from -advertise: a public
	// address, a WireGuard address, a Funnel URL...)
	Kind string `json:"kind"`
}

var (
	tailnetV4 = mustCIDR("100.64.0.0/10")
	tailnetV6 = mustCIDR("fd7a:115c:a1e0::/48")
)

func mustCIDR(cidr string) *net.IPNet {
	_, network, err := net.ParseCIDR(cidr)
	if err != nil {
		panic(err)
	}
	return network
}

// interfaces that are never a way in from another device: container and VM
// bridges
var skippedInterfaces = []string{"docker", "br-", "veth", "podman", "cni", "virbr", "vmnet", "bridge", "utun", "awdl", "llw"}

// localAddresses lists this machine's addresses another device could use,
// best first: home network IPv4, Tailscale, then global IPv6.
func localAddresses() []net.IP {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil
	}

	var ips []net.IP
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		// Tailscale's interface is named tailscale0 / utunN; its addresses
		// are recognised by range below, so only skip utun when it isn't
		// carrying a tailnet address
		skipped := false
		for _, prefix := range skippedInterfaces {
			if strings.HasPrefix(iface.Name, prefix) {
				skipped = true
			}
		}

		addresses, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, address := range addresses {
			network, ok := address.(*net.IPNet)
			if !ok {
				continue
			}
			ip := network.IP
			if skipped && !tailnetV4.Contains(ip) && !tailnetV6.Contains(ip) {
				continue
			}
			if ip.IsLinkLocalUnicast() || ip.IsLoopback() || ip.IsMulticast() {
				continue
			}
			ips = append(ips, ip)
		}
	}

	sort.SliceStable(ips, func(i, j int) bool { return addressRank(ips[i]) < addressRank(ips[j]) })
	return ips
}

func addressKind(ip net.IP) string {
	switch {
	case tailnetV4.Contains(ip) || tailnetV6.Contains(ip):
		return "tailscale"
	case ip.To4() != nil && ip.IsPrivate():
		return "lan"
	case ip.To4() == nil && ip.IsGlobalUnicast() && !ip.IsPrivate():
		return "ipv6"
	case ip.To4() != nil:
		return "advertised" // a public IPv4 on the interface itself
	}
	return ""
}

func addressRank(ip net.IP) int {
	switch addressKind(ip) {
	case "lan":
		return 0
	case "tailscale":
		return 1
	case "ipv6":
		return 2
	}
	return 3
}

// endpoints is what /v1/info offers: this machine's own addresses on the
// TLS port (if local), then whatever was advertised.
func endpoints(tlsPort int, local bool, advertised []string) []endpoint {
	var list []endpoint
	seen := map[string]bool{}

	add := func(e endpoint) {
		if e.URL != "" && !seen[e.URL] {
			seen[e.URL] = true
			list = append(list, e)
		}
	}

	// most systems keep several temporary IPv6 addresses, and a Tailscale
	// node has one of each family; a couple of each is enough to try
	limits := map[string]int{"lan": 4, "tailscale": 1, "ipv6": 2, "advertised": 2}
	counts := map[string]int{}

	if local && tlsPort > 0 {
		for _, ip := range localAddresses() {
			kind := addressKind(ip)
			if kind == "" || counts[kind] >= limits[kind] {
				continue
			}
			counts[kind]++
			add(endpoint{URL: "https://" + net.JoinHostPort(ip.String(), strconv.Itoa(tlsPort)), Kind: kind})
		}
	}

	for _, address := range advertised {
		add(endpoint{URL: normalizeAdvertised(address, tlsPort), Kind: "advertised"})
	}

	return list
}

// normalizeAdvertised accepts "203.0.113.5", "203.0.113.5:8443",
// "[2001:db8::1]:8443" or a full https URL.
func normalizeAdvertised(address string, tlsPort int) string {
	address = strings.TrimSpace(address)
	if address == "" {
		return ""
	}
	if strings.Contains(address, "://") {
		if u, err := url.Parse(address); err == nil && u.Scheme == "https" && u.Host != "" {
			return strings.TrimSuffix(u.String(), "/")
		}
		return ""
	}
	if _, _, err := net.SplitHostPort(address); err == nil {
		return "https://" + address
	}
	if tlsPort <= 0 {
		tlsPort = 443
	}
	return "https://" + net.JoinHostPort(strings.Trim(address, "[]"), strconv.Itoa(tlsPort))
}

// certificateIPs are the addresses named in the certificate.
func certificateIPs(advertised []string, local bool) []net.IP {
	var ips []net.IP
	if local {
		ips = localAddresses()
	}
	for _, address := range advertised {
		host := address
		if u, err := url.Parse(address); err == nil && u.Host != "" {
			host = u.Hostname()
		} else if h, _, err := net.SplitHostPort(address); err == nil {
			host = h
		}
		if ip := net.ParseIP(strings.Trim(host, "[]")); ip != nil {
			ips = append(ips, ip)
		}
	}
	return ips
}
