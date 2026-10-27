package main

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestNormalize(t *testing.T) {
	cases := map[string]string{
		"apps/v1/cert-manager/Deployment/cert-manager":                              "cert-manager/Deployment/cert-manager",
		"/v1/longhorn-system/Pod/instance-manager-46852e7560c0d2b8ed7c9e0ed23bcb4a": "longhorn-system/Pod/instance-manager-*",
		"/v1/arc-systems/Pod/lab-deploy-6dd469fc-listener":                          "arc-systems/Pod/lab-deploy-*-listener",
		"rbac.authorization.k8s.io/v1//ClusterRoleBinding/cluster-admin":            "/ClusterRoleBinding/cluster-admin",
		// Short or non-hex suffixes are real names and stay.
		"apps/v1/eightbitsaxlounge-prod/Deployment/eightbitsaxlounge-db": "eightbitsaxlounge-prod/Deployment/eightbitsaxlounge-db",
		"/v1/kube-system/Pod/etcd-1972-master-1":                         "kube-system/Pod/etcd-1972-master-1",
		// SA/Role/RoleBinding chain: the binding is what is kept.
		"//ServiceAccount/a/rbac.authorization.k8s.io/v1/ns/Role/r/rbac.authorization.k8s.io/v1/ns/RoleBinding/rb": "ns/RoleBinding/rb",
	}
	for in, want := range cases {
		if got := normalize(in); got != want {
			t.Errorf("normalize(%q) = %q, want %q", in, got, want)
		}
	}
}

const scanJSON = `{"results":[
 {"resourceID":"apps/v1/a/Deployment/x","controls":[
   {"controlID":"C-0013","name":"Non-root containers","status":{"status":"failed"}},
   {"controlID":"C-0017","name":"Immutable container filesystem","status":{"status":"passed"}}]},
 {"resourceID":"apps/v1/b/Deployment/y","controls":[
   {"controlID":"C-0013","name":"Non-root containers","status":{"status":"failed"}},
   {"controlID":"C-0057","name":"Privileged container","status":{"status":"failed"}}]}
]}`

func TestParseScan(t *testing.T) {
	failing, names, err := parseScan(strings.NewReader(scanJSON))
	if err != nil {
		t.Fatal(err)
	}
	want := []pair{{"C-0013", "a/Deployment/x"}, {"C-0013", "b/Deployment/y"}, {"C-0057", "b/Deployment/y"}}
	if len(failing) != len(want) {
		t.Fatalf("got %d failing pairs, want %d: %v", len(failing), len(want), failing)
	}
	for _, p := range want {
		if !failing[p] {
			t.Errorf("missing %v", p)
		}
	}
	if names["C-0057"] != "Privileged container" {
		t.Errorf("names[C-0057] = %q", names["C-0057"])
	}
}

func TestParseScanRejectsEmpty(t *testing.T) {
	if _, _, err := parseScan(strings.NewReader(`{"results":[]}`)); err == nil {
		t.Fatal("an empty scan must be an error, not a clean result")
	}
}

func TestParseAccepted(t *testing.T) {
	in := `
# C-0013 Non-root containers - chart defaults
C-0013 a/Deployment/x   # cert-manager
C-0057 b/Deployment/y
`
	got, err := parseAccepted(strings.NewReader(in))
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || !got[pair{"C-0013", "a/Deployment/x"}] || !got[pair{"C-0057", "b/Deployment/y"}] {
		t.Errorf("got %v", got)
	}
	for _, bad := range []string{"C-0013", "C-0013 a b", "0013 a/Deployment/x"} {
		if _, err := parseAccepted(strings.NewReader(bad)); err == nil {
			t.Errorf("parseAccepted(%q) should fail", bad)
		}
	}
}

func TestBuildAlertsGroupsByControl(t *testing.T) {
	now := time.Date(2026, 10, 27, 3, 30, 0, 0, time.UTC)
	regs := []pair{{"C-0013", "a/Deployment/x"}, {"C-0013", "b/Deployment/y"}, {"C-0057", "b/Deployment/y"}}
	alerts := buildAlerts(regs, map[string]string{"C-0013": "Non-root containers"}, now, time.Hour)
	if len(alerts) != 2 {
		t.Fatalf("got %d alerts, want one per control", len(alerts))
	}
	a := alerts[0]
	if a.Labels["alertname"] != "KubescapeRegression" || a.Labels["control"] != "C-0013" || a.Labels["source"] != "kubescape" {
		t.Errorf("labels = %v", a.Labels)
	}
	if !strings.Contains(a.Annotations["summary"], "2 resource(s)") || !strings.Contains(a.Annotations["description"], "b/Deployment/y") {
		t.Errorf("annotations = %v", a.Annotations)
	}
	if !a.EndsAt.Equal(now.Add(time.Hour)) {
		t.Errorf("EndsAt = %v", a.EndsAt)
	}
}

func writeFile(t *testing.T, dir, name, body string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestRunPostsOnlyRegressions(t *testing.T) {
	var got []alert
	am := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v2/alerts" {
			t.Errorf("path = %s", r.URL.Path)
		}
		if err := json.NewDecoder(r.Body).Decode(&got); err != nil {
			t.Error(err)
		}
	}))
	defer am.Close()

	dir := t.TempDir()
	cfg := config{
		ScanPath:     writeFile(t, dir, "scan.json", scanJSON),
		AcceptedPath: writeFile(t, dir, "accepted.txt", "C-0013 a/Deployment/x\nC-0013 b/Deployment/y\nC-0002 gone/Deployment/z\n"),
		Alertmanager: am.URL,
		Expire:       time.Hour,
	}
	logger := slog.New(slog.NewJSONHandler(io.Discard, nil))
	if err := run(cfg, logger, am.Client(), time.Now()); err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].Labels["control"] != "C-0057" {
		t.Errorf("posted %v, want only C-0057", got)
	}
}

func TestRunNothingToPost(t *testing.T) {
	am := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("nothing should be posted when every failure is accepted")
	}))
	defer am.Close()
	dir := t.TempDir()
	cfg := config{
		ScanPath:     writeFile(t, dir, "scan.json", scanJSON),
		AcceptedPath: writeFile(t, dir, "accepted.txt", "C-0013 a/Deployment/x\nC-0013 b/Deployment/y\nC-0057 b/Deployment/y\n"),
		Alertmanager: am.URL,
	}
	if err := run(cfg, slog.New(slog.NewJSONHandler(io.Discard, nil)), am.Client(), time.Now()); err != nil {
		t.Fatal(err)
	}
}

func TestRunFailsWhenAlertmanagerRefuses(t *testing.T) {
	am := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "nope", http.StatusBadRequest)
	}))
	defer am.Close()
	dir := t.TempDir()
	cfg := config{
		ScanPath:     writeFile(t, dir, "scan.json", scanJSON),
		AcceptedPath: writeFile(t, dir, "accepted.txt", ""),
		Alertmanager: am.URL,
	}
	if err := run(cfg, slog.New(slog.NewJSONHandler(io.Discard, nil)), am.Client(), time.Now()); err == nil {
		t.Fatal("a refused alert must fail the Job, or regressions vanish silently")
	}
}
