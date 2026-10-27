package main

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestClassify(t *testing.T) {
	cases := []struct {
		name    string
		found   bool
		desired int32
		ready   int32
		reasons []string
		want    State
	}{
		{"absent", false, 0, 0, nil, Unknown},
		{"scaled to zero", true, 0, 0, nil, Stopped},
		{"all ready", true, 2, 2, nil, Running},
		{"partly ready", true, 2, 1, nil, Degraded},
		{"crash loop wins over ready count", true, 1, 1, []string{"CrashLoopBackOff"}, Crashing},
		{"stopped wins over stale crash reason", true, 0, 0, []string{"CrashLoopBackOff"}, Stopped},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := classify("x", c.found, c.desired, c.ready, c.reasons, 0).State; got != c.want {
				t.Errorf("got %s, want %s", got, c.want)
			}
		})
	}
}

// fakeAPI serves canned JSON per path, and 403 for any namespace not listed,
// standing in for the Role being scoped to two namespaces.
func fakeAPI(t *testing.T, bodies map[string]string) *apiClient {
	t.Helper()
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer tok" {
			http.Error(w, "no token", http.StatusUnauthorized)
			return
		}
		if r.URL.Query().Get("labelSelector") != "app=eightbitsaxlounge" {
			http.Error(w, "unexpected selector", http.StatusBadRequest)
			return
		}
		body, ok := bodies[r.URL.Path]
		if !ok {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		_, _ = io.WriteString(w, body)
	}))
	t.Cleanup(ts.Close)
	tokenPath := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(tokenPath, []byte("tok\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return &apiClient{base: ts.URL, http: ts.Client(), tokenPath: tokenPath}
}

func testServer(t *testing.T, api *apiClient) *server {
	cfg := config{
		Namespaces: []string{"eightbitsaxlounge-prod", "eightbitsaxlounge-dev"},
		Selector:   "app=eightbitsaxlounge",
		Components: []string{"db", "state", "chat", "midi"},
	}
	return newServer(cfg, api, slog.New(slog.NewTextHandler(io.Discard, nil)))
}

func TestNamespaceView(t *testing.T) {
	prod := "/apis/apps/v1/namespaces/eightbitsaxlounge-prod/"
	api := fakeAPI(t, map[string]string{
		prod + "deployments": `{"items":[
			{"metadata":{"labels":{"component":"db"}},"spec":{"replicas":1},"status":{"readyReplicas":1}},
			{"metadata":{"labels":{"component":"chat"}},"spec":{"replicas":0},"status":{}},
			{"metadata":{"labels":{"component":"midi"}},"spec":{"replicas":1},"status":{"readyReplicas":0}}]}`,
		prod + "statefulsets": `{"items":[
			{"metadata":{"labels":{"component":"state"}},"spec":{"replicas":1},"status":{"readyReplicas":1}}]}`,
		"/api/v1/namespaces/eightbitsaxlounge-prod/pods": `{"items":[
			{"metadata":{"labels":{"component":"db"}},"status":{"containerStatuses":[{"restartCount":2,"state":{}}]}},
			{"metadata":{"labels":{"component":"midi"}},"status":{"containerStatuses":[{"restartCount":7,"state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}}]}`,
	})
	s := testServer(t, api)

	got := s.namespaceView(t.Context(), "eightbitsaxlounge-prod")
	if got.Error != "" {
		t.Fatalf("unexpected error: %s", got.Error)
	}
	want := map[string]State{"db": Running, "state": Running, "chat": Stopped, "midi": Crashing}
	for _, row := range got.Rows {
		if row.State != want[row.Component] {
			t.Errorf("%s: got %s, want %s", row.Component, row.State, want[row.Component])
		}
	}
	if got.Rows[0].Restarts != 2 {
		t.Errorf("db restarts: got %d, want 2", got.Rows[0].Restarts)
	}

	// dev has no canned responses, so the fake API refuses it - every row must
	// render as unknown, with the namespace-level error set, not as an empty table.
	dev := s.namespaceView(t.Context(), "eightbitsaxlounge-dev")
	if dev.Error == "" || len(dev.Rows) != 4 {
		t.Fatalf("refused namespace: error %q, %d rows", dev.Error, len(dev.Rows))
	}
	for _, row := range dev.Rows {
		if row.State != Unknown {
			t.Errorf("%s: got %s, want unknown", row.Component, row.State)
		}
	}
}

func TestPageAndHeaders(t *testing.T) {
	s := testServer(t, fakeAPI(t, nil))
	h := s.routes()

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("Cf-Access-Authenticated-User-Email", "<b>someone@example.com</b>")
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status %d", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "state-unknown") {
		t.Error("an unreachable API should render unknown rows")
	}
	if strings.Contains(body, "<b>someone") {
		t.Error("viewer header was not escaped")
	}
	if strings.Contains(body, "<script") || strings.Contains(body, "style=") {
		t.Error("page carries inline script or style, which the CSP forbids")
	}
	if csp := rec.Header().Get("Content-Security-Policy"); !strings.Contains(csp, "default-src 'none'") {
		t.Errorf("CSP: %q", csp)
	}

	for _, path := range []string{"/style.css", "/healthz"} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusOK {
			t.Errorf("%s: status %d", path, rec.Code)
		}
	}

	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/anything-else", nil))
	if rec.Code != http.StatusNotFound {
		t.Errorf("unknown path: status %d, want 404", rec.Code)
	}
}
