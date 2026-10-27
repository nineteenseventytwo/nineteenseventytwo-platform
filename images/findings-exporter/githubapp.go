package main

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// tokenSource supplies the bearer token for GitHub's API.
type tokenSource interface {
	token(ctx context.Context) (string, error)
}

// fileToken is a token in a file, re-read on every call: a personal access
// token, or `gh auth token` when running locally.
type fileToken struct{ path string }

func (f fileToken) token(context.Context) (string, error) {
	b, err := os.ReadFile(f.path)
	if err != nil {
		return "", fmt.Errorf("github token: %w", err)
	}
	return strings.TrimSpace(string(b)), nil
}

// githubApp authenticates as a GitHub App installation: a JWT signed with
// the App's private key buys a one-hour installation token. The App is its
// own, not ARC's - ARC's holds the org's self-hosted-runner admin permission,
// and a dashboard exporter has no business carrying that.
//
// The token request also narrows the permissions to security_events:read, so
// a later mistake in the App's settings does not widen what this process can
// do.
type githubApp struct {
	client         *http.Client
	api            string
	appID          string
	installationID string
	keyFile        string
	now            func() time.Time

	mu      sync.Mutex
	cached  string
	expires time.Time
}

func (g *githubApp) token(ctx context.Context) (string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	now := g.clock()
	if g.cached != "" && g.expires.Sub(now) > 5*time.Minute {
		return g.cached, nil
	}
	key, err := loadRSAKey(g.keyFile)
	if err != nil {
		return "", err
	}
	jwt, err := appJWT(key, g.appID, now)
	if err != nil {
		return "", err
	}
	body, _ := json.Marshal(map[string]any{
		"permissions": map[string]string{"security_events": "read"},
	})
	url := fmt.Sprintf("%s/app/installations/%s/access_tokens", strings.TrimRight(g.api, "/"), g.installationID)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+jwt)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	resp, err := g.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("github app token: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return "", fmt.Errorf("github app token: %s: %s", resp.Status, strings.TrimSpace(string(msg)))
	}
	var out struct {
		Token     string    `json:"token"`
		ExpiresAt time.Time `json:"expires_at"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", fmt.Errorf("github app token: %w", err)
	}
	g.cached, g.expires = out.Token, out.ExpiresAt
	return g.cached, nil
}

func (g *githubApp) clock() time.Time {
	if g.now != nil {
		return g.now()
	}
	return time.Now()
}

// appJWT is the RS256 JWT GitHub wants from an App: issued a minute in the
// past to absorb clock drift, valid nine minutes (the maximum is ten).
func appJWT(key *rsa.PrivateKey, appID string, now time.Time) (string, error) {
	enc := base64.RawURLEncoding
	header := enc.EncodeToString([]byte(`{"alg":"RS256","typ":"JWT"}`))
	claims, err := json.Marshal(map[string]any{
		"iat": now.Add(-time.Minute).Unix(),
		"exp": now.Add(9 * time.Minute).Unix(),
		"iss": appID,
	})
	if err != nil {
		return "", err
	}
	signing := header + "." + enc.EncodeToString(claims)
	sum := sha256.Sum256([]byte(signing))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, sum[:])
	if err != nil {
		return "", err
	}
	return signing + "." + enc.EncodeToString(sig), nil
}

// loadRSAKey reads the App's private key. GitHub issues PKCS#1 ("BEGIN RSA
// PRIVATE KEY"); PKCS#8 is accepted too, in case it was converted.
func loadRSAKey(path string) (*rsa.PrivateKey, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("github app key: %w", err)
	}
	block, _ := pem.Decode(b)
	if block == nil {
		return nil, fmt.Errorf("github app key: no PEM block in %s", path)
	}
	if k, err := x509.ParsePKCS1PrivateKey(block.Bytes); err == nil {
		return k, nil
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("github app key: %w", err)
	}
	rk, ok := k.(*rsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("github app key: not an RSA key")
	}
	return rk, nil
}
