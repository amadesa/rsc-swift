package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"
)

var (
	// errGap means the client asked for an offset the relay can't serve:
	// data it already acknowledged, or bytes it hasn't sent yet
	errGap    = errors.New("offset doesn't match the relay's stream position")
	errClosed = errors.New("connection closed")
)

// session is one game connection. Bytes from the server are kept until the
// client acknowledges them (by asking for a later offset), so a lost
// response can be fetched again.
type session struct {
	id      string
	conn    net.Conn
	client  string // for the log
	address string
	opened  time.Time

	mu       sync.Mutex
	changed  chan struct{} // closed when data arrives or the connection ends
	down     []byte        // unacknowledged bytes from the server
	downBase int64         // stream offset of down[0]
	closed   bool
	upNext   int64 // stream offset of the next byte to send to the server
	lastSeen time.Time
	received int64  // bytes from the server, in total
	ended    string // why the server side ended, if it has

	writeMu sync.Mutex // keeps sends in order
}

func newSession(id string, conn net.Conn, client, address string) *session {
	now := time.Now()
	return &session{
		id: id, conn: conn, client: client, address: address, opened: now,
		changed: make(chan struct{}), lastSeen: now,
	}
}

// summary describes the session as it closes, for the log.
func (s *session) summary(reason string) string {
	s.mu.Lock()
	defer s.mu.Unlock()

	line := fmt.Sprintf("%s after %s (sent %s, received %s)", reason,
		time.Since(s.opened).Round(time.Second), size(s.upNext), size(s.received))

	if s.ended != "" {
		line += "; " + s.ended
	} else if s.received == 0 {
		line += "; the game server never replied"
	}
	return line
}

func (s *session) touch() {
	s.mu.Lock()
	s.lastSeen = time.Now()
	s.mu.Unlock()
}

func (s *session) idleFor() time.Duration {
	s.mu.Lock()
	defer s.mu.Unlock()
	return time.Since(s.lastSeen)
}

// notify wakes waiting reads. Must hold s.mu.
func (s *session) notify() {
	close(s.changed)
	s.changed = make(chan struct{})
}

func (s *session) readLoop() {
	buf := make([]byte, 32<<10)
	for {
		n, err := s.conn.Read(buf)

		s.mu.Lock()
		if n > 0 {
			if len(s.down)+n > maxBuffered {
				// the client stopped reading; don't buffer forever
				err = errors.New("client fell too far behind")
			} else {
				s.down = append(s.down, buf[:n]...)
				s.received += int64(n)
			}
		}
		if err != nil {
			s.closed = true
			if s.ended == "" {
				s.ended = endReason(err)
			}
		}
		s.notify()
		s.mu.Unlock()

		if err != nil {
			s.conn.Close()
			return
		}
	}
}

// read returns the bytes from offset from, waiting up to wait for some to
// arrive. Asking for offset from acknowledges everything before it.
func (s *session) read(ctx context.Context, from int64, wait time.Duration) (data []byte, closed bool, err error) {
	timer := time.NewTimer(wait)
	defer timer.Stop()

	for {
		s.mu.Lock()
		end := s.downBase + int64(len(s.down))
		if from < s.downBase || from > end {
			s.mu.Unlock()
			return nil, false, errGap
		}

		// drop what the client now has; copy so the buffer doesn't pin memory
		if from > s.downBase {
			s.down = append([]byte(nil), s.down[from-s.downBase:]...)
			s.downBase = from
		}

		if len(s.down) > 0 || s.closed {
			data = append([]byte(nil), s.down[:min(len(s.down), maxRecvBytes)]...)
			closed = s.closed
			s.mu.Unlock()
			return data, closed, nil
		}

		changed := s.changed
		s.mu.Unlock()

		select {
		case <-changed:
		case <-timer.C:
			return nil, false, nil
		case <-ctx.Done():
			return nil, false, ctx.Err()
		}
	}
}

// write sends data whose first byte is at stream offset at. Bytes the relay
// already sent (a retried request) are skipped.
func (s *session) write(at int64, data []byte) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()

	s.mu.Lock()
	next, closed := s.upNext, s.closed
	s.mu.Unlock()

	if closed {
		return errClosed
	}
	if at > next {
		return errGap
	}
	if skip := next - at; skip >= int64(len(data)) {
		return nil
	} else {
		data = data[skip:]
	}

	s.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	n, err := s.conn.Write(data)

	s.mu.Lock()
	s.upNext += int64(n)
	s.mu.Unlock()

	return err
}

// endReason says why the game connection ended.
func endReason(err error) string {
	switch {
	case errors.Is(err, io.EOF):
		return "the game server closed the connection"
	case errors.Is(err, net.ErrClosed):
		return "" // the relay closed it
	}
	return "the game connection failed: " + dialError(err)
}
