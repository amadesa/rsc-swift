package main

import (
	"encoding/binary"
	"errors"
	"log"
	"net"
	"strings"
	"time"
)

// Announces the relay on the home network with Bonjour (multicast DNS), as
// _rsc-relay._tcp, so the iPhone can list it for pairing without anyone
// typing an address. The TXT record carries the key fingerprint and
// version. Only what's needed is answered: the service list, the service's
// SRV and TXT, and this host's IPv4 addresses.
//
// On a Mac, mDNSResponder already owns port 5353; the socket is shared
// (SO_REUSEPORT) as other responders do. With Avahi on Linux the same.

const (
	mdnsService = "_rsc-relay._tcp.local."
	mdnsTTL     = 120

	typeA   = 1
	typePTR = 12
	typeTXT = 16
	typeSRV = 33
	typeANY = 255
	classIN = 1
	// in an answer: replace older records for this name
	cacheFlush = 0x8000
	// in a question: the asker wants a unicast reply
	unicastResponse = 0x8000
)

var mdnsGroup = &net.UDPAddr{IP: net.IPv4(224, 0, 0, 251), Port: 5353}

type mdnsResponder struct {
	instance string // "11700._rsc-relay._tcp.local."
	host     string // "11700-rsc-relay.local."
	port     int
	txt      []string
	addrs    func() []net.IP
}

func newMDNS(name string, port int, pin string) *mdnsResponder {
	label := mdnsLabel(name)
	return &mdnsResponder{
		instance: label + "." + mdnsService,
		host:     label + "-rsc-relay.local.",
		port:     port,
		txt:      []string{"v=" + version, "pin=" + pin},
		addrs: func() []net.IP {
			var ips []net.IP
			for _, ip := range localAddresses() {
				if addressKind(ip) == "lan" {
					ips = append(ips, ip.To4())
				}
			}
			return ips
		},
	}
}

// run answers queries until the socket fails. Errors are logged; Bonjour is
// a convenience, the relay works without it.
func (m *mdnsResponder) run() {
	conn, err := net.ListenMulticastUDP("udp4", nil, mdnsGroup)
	if err != nil {
		log.Printf("Bonjour: can't listen on 5353 (%v); pair by typing the address instead", err)
		return
	}
	defer conn.Close()
	log.Printf("Bonjour: announcing %s", strings.TrimSuffix(m.instance, "."))

	// announce twice, a second apart, as RFC 6762 asks
	for i := 0; i < 2; i++ {
		conn.WriteToUDP(m.response(typePTR, mdnsService), mdnsGroup)
		time.Sleep(time.Second)
	}

	buf := make([]byte, 9000)
	for {
		n, from, err := conn.ReadFromUDP(buf)
		if err != nil {
			log.Printf("Bonjour: %v", err)
			return
		}
		questions, err := parseQuestions(buf[:n])
		if err != nil {
			continue
		}
		for _, q := range questions {
			reply := m.response(q.qtype, q.name)
			if reply == nil {
				continue
			}
			// a one-shot query (not from 5353) or one asking for unicast
			// gets the answer back directly; everyone else hears it too
			if from.Port != 5353 || q.unicast {
				conn.WriteToUDP(reply, from)
			}
			if from.Port == 5353 {
				conn.WriteToUDP(reply, mdnsGroup)
			}
		}
	}
}

type question struct {
	name    string
	qtype   uint16
	unicast bool
}

func parseQuestions(msg []byte) ([]question, error) {
	if len(msg) < 12 {
		return nil, errors.New("short")
	}
	// responses (QR bit) aren't questions to answer
	if msg[2]&0x80 != 0 {
		return nil, errors.New("response")
	}
	count := int(binary.BigEndian.Uint16(msg[4:6]))
	offset := 12

	var questions []question
	for i := 0; i < count; i++ {
		name, next, err := readName(msg, offset)
		if err != nil || next+4 > len(msg) {
			return questions, errors.New("bad question")
		}
		qtype := binary.BigEndian.Uint16(msg[next : next+2])
		class := binary.BigEndian.Uint16(msg[next+2 : next+4])
		questions = append(questions, question{
			name: strings.ToLower(name), qtype: qtype, unicast: class&unicastResponse != 0,
		})
		offset = next + 4
	}
	return questions, nil
}

// readName reads a possibly compressed name, returning it and the offset
// just after it in the message.
func readName(msg []byte, offset int) (string, int, error) {
	var labels []string
	end := -1
	for jumps := 0; jumps < 16; {
		if offset >= len(msg) {
			return "", 0, errors.New("name past end")
		}
		length := int(msg[offset])
		switch {
		case length == 0:
			if end < 0 {
				end = offset + 1
			}
			return strings.Join(labels, ".") + ".", end, nil
		case length&0xc0 == 0xc0:
			if offset+1 >= len(msg) {
				return "", 0, errors.New("bad pointer")
			}
			if end < 0 {
				end = offset + 2
			}
			offset = int(binary.BigEndian.Uint16(msg[offset:offset+2]) & 0x3fff)
			jumps++
		default:
			if offset+1+length > len(msg) {
				return "", 0, errors.New("label past end")
			}
			labels = append(labels, string(msg[offset+1:offset+1+length]))
			offset += 1 + length
		}
	}
	return "", 0, errors.New("too many pointers")
}

// response answers one question, or returns nil if it isn't about us.
func (m *mdnsResponder) response(qtype uint16, name string) []byte {
	var answers, extra [][]byte
	wants := func(t uint16) bool { return qtype == t || qtype == typeANY }

	switch strings.ToLower(name) {
	case strings.ToLower(mdnsService):
		if !wants(typePTR) {
			return nil
		}
		answers = append(answers, record(mdnsService, typePTR, 0, encodeName(m.instance)))
		extra = append(extra, m.srv(), m.txtRecord())
		extra = append(extra, m.aRecords()...)
	case strings.ToLower(m.instance):
		if wants(typeSRV) {
			answers = append(answers, m.srv())
			extra = append(extra, m.aRecords()...)
		}
		if wants(typeTXT) {
			answers = append(answers, m.txtRecord())
		}
	case strings.ToLower(m.host):
		if wants(typeA) {
			answers = append(answers, m.aRecords()...)
		}
	default:
		return nil
	}
	if len(answers) == 0 {
		return nil
	}

	msg := make([]byte, 12)
	binary.BigEndian.PutUint16(msg[2:4], 0x8400) // response, authoritative
	binary.BigEndian.PutUint16(msg[6:8], uint16(len(answers)))
	binary.BigEndian.PutUint16(msg[10:12], uint16(len(extra)))
	for _, r := range append(answers, extra...) {
		msg = append(msg, r...)
	}
	return msg
}

func (m *mdnsResponder) srv() []byte {
	data := make([]byte, 6)
	binary.BigEndian.PutUint16(data[4:6], uint16(m.port))
	return record(m.instance, typeSRV, cacheFlush, append(data, encodeName(m.host)...))
}

func (m *mdnsResponder) txtRecord() []byte {
	var data []byte
	for _, entry := range m.txt {
		data = append(data, byte(len(entry)))
		data = append(data, entry...)
	}
	return record(m.instance, typeTXT, cacheFlush, data)
}

func (m *mdnsResponder) aRecords() [][]byte {
	var records [][]byte
	for _, ip := range m.addrs() {
		records = append(records, record(m.host, typeA, cacheFlush, ip))
	}
	return records
}

func record(name string, rtype uint16, flags uint16, data []byte) []byte {
	out := encodeName(name)
	header := make([]byte, 10)
	binary.BigEndian.PutUint16(header[0:2], rtype)
	binary.BigEndian.PutUint16(header[2:4], classIN|flags)
	binary.BigEndian.PutUint32(header[4:8], mdnsTTL)
	binary.BigEndian.PutUint16(header[8:10], uint16(len(data)))
	return append(append(out, header...), data...)
}

func encodeName(name string) []byte {
	var out []byte
	for _, label := range strings.Split(strings.TrimSuffix(name, "."), ".") {
		out = append(out, byte(len(label)))
		out = append(out, label...)
	}
	return append(out, 0)
}

// mdnsLabel makes a host name fit to be a DNS label.
func mdnsLabel(name string) string {
	label := strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-':
			return r
		}
		return '-'
	}, name)
	label = strings.Trim(label, "-")
	if label == "" {
		label = "rsc-relay"
	}
	if len(label) > 40 {
		label = label[:40]
	}
	return label
}
