package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// Paired devices each have their own token, so one can be removed without
// touching the others. Only a hash of each token is stored. The relay
// rereads the file when it changes, so `rsc-relay devices` works while it
// runs.

const devicesFile = "devices.json"

type device struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	TokenHash string    `json:"token_sha256"`
	Created   time.Time `json:"created"`
}

type deviceStore struct {
	path string

	mu      sync.Mutex
	devices []device
	byHash  map[string]*device
	modTime time.Time
	checked time.Time
}

func openDevices(dir string) (*deviceStore, error) {
	store := &deviceStore{path: filepath.Join(dir, devicesFile)}
	if err := store.load(); err != nil {
		return nil, err
	}
	return store, nil
}

func hashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// load reads the file, or starts empty if there isn't one. Called with mu
// held, or before the store is shared.
func (s *deviceStore) load() error {
	info, err := os.Stat(s.path)
	if errors.Is(err, os.ErrNotExist) {
		s.devices, s.byHash, s.modTime = nil, map[string]*device{}, time.Time{}
		return nil
	} else if err != nil {
		return err
	}

	data, err := os.ReadFile(s.path)
	if err != nil {
		return err
	}

	var devices []device
	if err := json.Unmarshal(data, &devices); err != nil {
		return fmt.Errorf("%s: %w", s.path, err)
	}

	s.devices = devices
	s.byHash = map[string]*device{}
	for i := range s.devices {
		s.byHash[s.devices[i].TokenHash] = &s.devices[i]
	}
	s.modTime = info.ModTime()
	return nil
}

func (s *deviceStore) save() error {
	data, err := json.MarshalIndent(s.devices, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}

	temporary := s.path + ".tmp"
	if err := os.WriteFile(temporary, append(data, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(temporary, s.path)
}

// lookup returns the device with this token, if any.
func (s *deviceStore) lookup(token string) (device, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()

	// pick up changes from `rsc-relay devices`, checking at most every 2 s
	if now := time.Now(); now.Sub(s.checked) > 2*time.Second {
		s.checked = now
		if info, err := os.Stat(s.path); err == nil && !info.ModTime().Equal(s.modTime) {
			s.load()
		} else if errors.Is(err, os.ErrNotExist) && len(s.devices) > 0 {
			s.load()
		}
	}

	found := s.byHash[hashToken(token)]
	if found == nil {
		return device{}, false
	}
	return *found, true
}

// add pairs a new device and returns its token, which isn't stored.
func (s *deviceStore) add(name string) (device, string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if err := s.load(); err != nil {
		return device{}, "", err
	}

	token := randomHex(24)
	d := device{
		ID:        randomHex(4),
		Name:      cleanName(name),
		TokenHash: hashToken(token),
		Created:   time.Now().UTC().Truncate(time.Second),
	}
	s.devices = append(s.devices, d)
	if err := s.save(); err != nil {
		return device{}, "", err
	}
	s.load()
	return d, token, nil
}

// remove unpairs the device with this id (or unique id prefix, or name).
func (s *deviceStore) remove(which string) (device, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if err := s.load(); err != nil {
		return device{}, err
	}

	index := -1
	for i, d := range s.devices {
		if d.ID == which || strings.EqualFold(d.Name, which) || strings.HasPrefix(d.ID, which) {
			if index >= 0 {
				return device{}, fmt.Errorf("%q matches more than one device", which)
			}
			index = i
		}
	}
	if index < 0 {
		return device{}, fmt.Errorf("no device %q", which)
	}

	removed := s.devices[index]
	s.devices = append(s.devices[:index], s.devices[index+1:]...)
	if err := s.save(); err != nil {
		return device{}, err
	}
	s.load()
	return removed, nil
}

func (s *deviceStore) list() []device {
	s.mu.Lock()
	defer s.mu.Unlock()

	devices := append([]device(nil), s.devices...)
	sort.Slice(devices, func(i, j int) bool { return devices[i].Created.Before(devices[j].Created) })
	return devices
}

func cleanName(name string) string {
	name = strings.Map(func(r rune) rune {
		if r < ' ' || r == 0x7f {
			return -1
		}
		return r
	}, strings.TrimSpace(name))
	if name == "" {
		return "device"
	}
	if len(name) > 40 {
		name = name[:40]
	}
	return name
}
