package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"
)

// The relay's identity is a P-256 key made on first start and kept in the
// data directory. Apps pin its public key rather than trusting a name or a
// certificate authority, so any address that reaches the relay (home
// network, public IP, Tailscale, WireGuard) is as trustworthy as any other.
//
// The certificate around the key is self-signed and remade on every start;
// only the key matters.

const identityFile = "identity.pem"

// certificate lifetime: within what Apple accepts for TLS server
// certificates, and remade on every start anyway
const certificateLifetime = 800 * 24 * time.Hour

type identity struct {
	key *ecdsa.PrivateKey
	// "sha256/<base64>": the SHA-256 of the key's SubjectPublicKeyInfo, as
	// `curl --pinnedpubkey` takes it
	pin string
}

func loadOrCreateIdentity(dir string) (*identity, error) {
	path := filepath.Join(dir, identityFile)

	key, err := readKey(path)
	if errors.Is(err, os.ErrNotExist) {
		key, err = createKey(path)
	}
	if err != nil {
		return nil, err
	}

	spki, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(spki)

	return &identity{key: key, pin: "sha256/" + base64.StdEncoding.EncodeToString(sum[:])}, nil
}

func readKey(path string) (*ecdsa.PrivateKey, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	block, _ := pem.Decode(data)
	if block == nil || block.Type != "PRIVATE KEY" {
		return nil, fmt.Errorf("%s doesn't hold a PEM private key", path)
	}

	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}

	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok || key.Curve != elliptic.P256() {
		return nil, fmt.Errorf("%s isn't a P-256 key", path)
	}
	return key, nil
}

func createKey(path string) (*ecdsa.PrivateKey, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}

	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, err
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	data := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	// O_EXCL: never replace a key apps have already pinned
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	if _, err := file.Write(data); err != nil {
		return nil, err
	}

	return key, nil
}

// certificate makes a self-signed certificate for the key, naming the
// addresses the relay can be reached at (for tools that check names; the
// apps check the key).
func (id *identity) certificate(ips []net.IP) (tls.Certificate, error) {
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
	if err != nil {
		return tls.Certificate{}, err
	}

	now := time.Now()
	template := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "rsc-relay"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(certificateLifetime),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              []string{"rsc-relay"},
		IPAddresses:           ips,
	}

	der, err := x509.CreateCertificate(rand.Reader, template, template, &id.key.PublicKey, id.key)
	if err != nil {
		return tls.Certificate{}, err
	}

	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: id.key}, nil
}
