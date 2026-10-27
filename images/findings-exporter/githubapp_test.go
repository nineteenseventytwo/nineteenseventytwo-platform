package main

import (
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
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeKey(t *testing.T, key *rsa.PrivateKey) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "key.pem")
	pemBytes := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})
	if err := os.WriteFile(p, pemBytes, 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestAppJWTVerifies(t *testing.T) {
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	now := time.Unix(1793000000, 0)
	jwt, err := appJWT(key, "12345", now)
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(jwt, ".")
	if len(parts) != 3 {
		t.Fatalf("jwt has %d parts", len(parts))
	}
	sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if err := rsa.VerifyPKCS1v15(&key.PublicKey, crypto.SHA256, sum[:], sig); err != nil {
		t.Fatalf("signature does not verify: %v", err)
	}
	raw, _ := base64.RawURLEncoding.DecodeString(parts[1])
	var claims map[string]any
	json.Unmarshal(raw, &claims)
	if claims["iss"] != "12345" || claims["iat"].(float64) != 1792999940 || claims["exp"].(float64) != 1793000540 {
		t.Errorf("claims = %v", claims)
	}
}

func TestLoadRSAKeyPKCS8(t *testing.T) {
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	p := filepath.Join(t.TempDir(), "k8.pem")
	os.WriteFile(p, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600)
	if _, err := loadRSAKey(p); err != nil {
		t.Fatal(err)
	}
}

func TestGitHubAppTokenNarrowsAndCaches(t *testing.T) {
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	now := time.Date(2026, 10, 27, 15, 0, 0, 0, time.UTC)
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Method != http.MethodPost || r.URL.Path != "/app/installations/678/access_tokens" {
			t.Errorf("%s %s", r.Method, r.URL.Path)
		}
		if !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ey") {
			t.Errorf("Authorization = %q", r.Header.Get("Authorization"))
		}
		var body struct {
			Permissions map[string]string `json:"permissions"`
		}
		json.NewDecoder(r.Body).Decode(&body)
		if len(body.Permissions) != 1 || body.Permissions["security_events"] != "read" {
			t.Errorf("permissions = %v, want only security_events:read", body.Permissions)
		}
		w.WriteHeader(http.StatusCreated)
		fmt.Fprintf(w, `{"token":"ghs_x","expires_at":%q}`, now.Add(time.Hour).Format(time.RFC3339))
	}))
	defer srv.Close()
	app := &githubApp{client: srv.Client(), api: srv.URL, appID: "1", installationID: "678",
		keyFile: writeKey(t, key), now: func() time.Time { return now }}
	for i := 0; i < 3; i++ {
		tok, err := app.token(context.Background())
		if err != nil || tok != "ghs_x" {
			t.Fatalf("token = %q, %v", tok, err)
		}
	}
	if calls != 1 {
		t.Errorf("exchanged %d times; a valid token must be reused", calls)
	}
	now = now.Add(56 * time.Minute) // within 5 minutes of expiry
	if _, err := app.token(context.Background()); err != nil {
		t.Fatal(err)
	}
	if calls != 2 {
		t.Errorf("exchanged %d times; a nearly expired token must be renewed", calls)
	}
}
