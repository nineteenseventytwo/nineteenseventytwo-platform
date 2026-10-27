package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// AWS's published SigV4 examples for S3 ("Signature Calculations for the
// Authorization Header: Transferring Payload in a Single Chunk"), with the
// documentation's example credentials. If the canonical request or the key
// derivation drifts, these signatures change.
var awsExample = credentials{
	AccessKeyID:     "AKIAIOSFODNN7EXAMPLE",
	SecretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
}
var awsExampleTime = time.Date(2013, 5, 24, 0, 0, 0, 0, time.UTC)

func sigOf(t *testing.T, req *http.Request) string {
	t.Helper()
	auth := req.Header.Get("Authorization")
	i := strings.Index(auth, "Signature=")
	if i < 0 {
		t.Fatalf("no signature in %q", auth)
	}
	return auth[i+len("Signature="):]
}

func TestSignV4GetObject(t *testing.T) {
	req, _ := http.NewRequest(http.MethodGet, "https://examplebucket.s3.amazonaws.com/test.txt", nil)
	req.Header.Set("Range", "bytes=0-9")
	signV4(req, awsExample, "us-east-1", "s3", awsExampleTime)
	if got, want := sigOf(t, req), "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"; got != want {
		t.Errorf("signature = %s, want %s", got, want)
	}
	if !strings.Contains(req.Header.Get("Authorization"), "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,") {
		t.Errorf("Authorization = %s", req.Header.Get("Authorization"))
	}
}

func TestSignV4ListObjects(t *testing.T) {
	req, _ := http.NewRequest(http.MethodGet, "https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J", nil)
	signV4(req, awsExample, "us-east-1", "s3", awsExampleTime)
	if got, want := sigOf(t, req), "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"; got != want {
		t.Errorf("signature = %s, want %s", got, want)
	}
}

func TestSignV4SessionToken(t *testing.T) {
	req, _ := http.NewRequest(http.MethodGet, "https://b.s3.eu-west-2.amazonaws.com/", nil)
	c := awsExample
	c.SessionToken = "tok"
	signV4(req, c, "eu-west-2", "s3", awsExampleTime)
	if req.Header.Get("X-Amz-Security-Token") != "tok" ||
		!strings.Contains(req.Header.Get("Authorization"), "x-amz-security-token") {
		t.Errorf("session token not set and signed: %v", req.Header)
	}
}

func TestAWSEscape(t *testing.T) {
	if got := awsEscape("findings/a b+c~"); got != "findings%2Fa%20b%2Bc~" {
		t.Errorf("awsEscape = %q", got)
	}
	u, _ := url.Parse("https://h/findings/json-ocsf/a%20b.json")
	if got := canonicalPath(u); got != "/findings/json-ocsf/a%20b.json" {
		t.Errorf("canonicalPath = %q", got)
	}
}

func TestNormalizeSeverity(t *testing.T) {
	cases := map[string]string{
		"Critical": "critical", "Emergency": "critical",
		"High": "high", "error": "high",
		"Warning": "medium", "medium": "medium",
		"Notice": "low", "note": "low",
		"Informational": "info", "": "unknown", "bogus": "unknown",
	}
	for in, want := range cases {
		if got := normalizeSeverity(in); got != want {
			t.Errorf("normalizeSeverity(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestParseOCSF(t *testing.T) {
	in := `[
	 {"status_code":"FAIL","status":"New","severity":"High","metadata":{"event_code":"s3_bucket_no_mfa_delete"}},
	 {"status_code":"FAIL","status":"Suppressed","severity":"Critical","metadata":{"event_code":"muted_check"}},
	 {"status_code":"PASS","status":"New","severity":"High","metadata":{"event_code":"passing"}},
	 {"status_code":"FAIL","status":"New","severity":"Low","metadata":{"event_code":"iam_x"},"extra":{"nested":[1,2]}}
	]`
	got, err := parseOCSF(strings.NewReader(in))
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].Item != "s3_bucket_no_mfa_delete" || got[0].Severity != "high" ||
		got[1].Item != "iam_x" || got[1].Severity != "low" {
		t.Errorf("got %+v", got)
	}
	if _, err := parseOCSF(strings.NewReader(`{"not":"an array"}`)); err == nil {
		t.Error("a non-array report must be an error")
	}
}

func TestNextLink(t *testing.T) {
	h := `<https://api.github.com/x?page=2>; rel="next", <https://api.github.com/x?page=5>; rel="last"`
	if got := nextLink(h); got != "https://api.github.com/x?page=2" {
		t.Errorf("nextLink = %q", got)
	}
	if got := nextLink(`<https://api.github.com/x?page=1>; rel="prev"`); got != "" {
		t.Errorf("nextLink without next = %q", got)
	}
}

func TestAlertmanagerSource(t *testing.T) {
	am := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v2/alerts" || r.URL.Query().Get("silenced") != "false" {
			t.Errorf("request %s", r.URL)
		}
		fmt.Fprint(w, `[
		 {"labels":{"source":"falco","priority":"Warning","rule":"Read sensitive file untrusted"},"startsAt":"2026-10-27T11:47:22Z"},
		 {"labels":{"source":"kubescape","severity":"warning","control":"C-0013"},"startsAt":"2026-10-27T13:30:00Z"},
		 {"labels":{"alertname":"KubeJobFailed","severity":"warning"},"startsAt":"2026-10-27T13:30:00Z"}
		]`)
	}))
	defer am.Close()
	src := &alertmanagerSource{client: am.Client(), base: am.URL, sources: []string{"falco", "kubescape"}}
	got, err := src.collect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if f := got["falco"]; len(f) != 1 || f[0].Severity != "medium" || f[0].Item != "Read sensitive file untrusted" {
		t.Errorf("falco = %+v", f)
	}
	if k := got["kubescape"]; len(k) != 1 || k[0].Item != "C-0013" {
		t.Errorf("kubescape = %+v", k)
	}
	if len(got) != 2 {
		t.Errorf("alerts without a finding source must be ignored: %v", got)
	}
}

func TestGitHubSourcePaginatesAndFilters(t *testing.T) {
	var srv *httptest.Server
	srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer secret" {
			t.Errorf("Authorization = %q", r.Header.Get("Authorization"))
		}
		if r.URL.Query().Get("page") == "" {
			w.Header().Set("Link", fmt.Sprintf(`<%s%s?state=open&page=2>; rel="next"`, srv.URL, r.URL.Path))
			fmt.Fprint(w, `[{"created_at":"2026-09-01T00:00:00Z","rule":{"id":"CVE-1","severity":"error","security_severity_level":"critical"},"tool":{"name":"Trivy"},"most_recent_instance":{"category":"quay.io_cilium_cilium"}}]`)
			return
		}
		fmt.Fprint(w, `[{"created_at":"2026-10-01T00:00:00Z","rule":{"id":"CKV_K8S_11","severity":"error"},"tool":{"name":"checkov"},"most_recent_instance":{"category":"x"}},
		                {"created_at":"2026-10-01T00:00:00Z","rule":{"id":"go/x","severity":"warning"},"tool":{"name":"CodeQL"}}]`)
	}))
	defer srv.Close()
	tok := filepath.Join(t.TempDir(), "token")
	os.WriteFile(tok, []byte("secret\n"), 0o600)
	src := &githubSource{client: srv.Client(), api: srv.URL, repos: []string{"o/r"}, tools: []string{"trivy", "checkov"}, auth: fileToken{path: tok}}
	got, err := src.collect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if tr := got["trivy"]; len(tr) != 1 || tr[0].Severity != "critical" || tr[0].Item != "quay.io_cilium_cilium" {
		t.Errorf("trivy = %+v", tr)
	}
	if ck := got["checkov"]; len(ck) != 1 || ck[0].Severity != "high" || ck[0].Item != "CKV_K8S_11" {
		t.Errorf("checkov = %+v", ck)
	}
	if _, ok := got["codeql"]; ok {
		t.Error("tools not configured must be ignored")
	}
}

type staticCreds struct{ c credentials }

func (s staticCreds) get(context.Context) (credentials, error) { return s.c, nil }

func TestProwlerSourcePicksNewestAndCaches(t *testing.T) {
	gets := 0
	s3 := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.Header.Get("Authorization"), "AWS4-HMAC-SHA256 ") {
			t.Errorf("unsigned request %s", r.URL)
		}
		switch r.URL.Path {
		case "/":
			fmt.Fprint(w, `<ListBucketResult>
			 <Contents><Key>findings/json-ocsf/old.ocsf.json</Key><LastModified>2026-10-25T05:10:00Z</LastModified></Contents>
			 <Contents><Key>findings/html/new.html</Key><LastModified>2026-10-27T05:10:00Z</LastModified></Contents>
			 <Contents><Key>findings/json-ocsf/new.ocsf.json</Key><LastModified>2026-10-27T05:10:00Z</LastModified></Contents>
			 <IsTruncated>false</IsTruncated></ListBucketResult>`)
		case "/findings/json-ocsf/new.ocsf.json":
			gets++
			fmt.Fprint(w, `[{"status_code":"FAIL","status":"New","severity":"Medium","metadata":{"event_code":"c1"}}]`)
		default:
			t.Errorf("unexpected GET %s", r.URL.Path)
			http.NotFound(w, r)
		}
	}))
	defer s3.Close()
	src := &prowlerSource{client: s3.Client(), bucket: "b", prefix: "findings/", region: "eu-west-2",
		creds: staticCreds{awsExample}, endpoint: s3.URL}
	for i := 0; i < 2; i++ {
		got, err := src.collect(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if p := got["prowler"]; len(p) != 1 || p[0].Item != "c1" || p[0].Severity != "medium" {
			t.Errorf("prowler = %+v", p)
		}
	}
	if gets != 1 {
		t.Errorf("report downloaded %d times; an unchanged report must not be re-downloaded", gets)
	}
	if at := src.dataTimes()["prowler"]; !at.Equal(time.Date(2026, 10, 27, 5, 10, 0, 0, time.UTC)) {
		t.Errorf("data time = %v, want the newest report's LastModified", at)
	}
}

func TestStoreWrite(t *testing.T) {
	s := newStore()
	t0 := time.Unix(1700000000, 0)
	s.set("falco", []finding{
		{Severity: "medium", Item: `rule "quoted"`, Since: t0.Add(time.Hour)},
		{Severity: "medium", Item: `rule "quoted"`, Since: t0},
	}, t0)
	s.set("trivy", nil, t0)
	s.fail("prowler")
	s.set("kubescape", nil, t0)
	s.setDataTime("kubescape", t0.Add(-time.Hour))
	var b strings.Builder
	s.write(&b)
	out := b.String()
	for _, want := range []string{
		`findings_open{source="falco",severity="medium",item="rule \"quoted\""} 2`,
		`findings_oldest_open_timestamp_seconds{source="falco",severity="medium"} 1700000000`,
		`findings_source_up{source="falco"} 1`,
		`findings_source_up{source="prowler"} 0`,
		`findings_source_up{source="trivy"} 1`,
		`findings_source_last_success_timestamp_seconds{source="trivy"} 1700000000`,
		`findings_source_data_timestamp_seconds{source="kubescape"} 1699996400`,
	} {
		if !strings.Contains(out, want+"\n") {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	if strings.Contains(out, `last_success_timestamp_seconds{source="prowler"}`) {
		t.Error("a source that never succeeded has no last-success time")
	}
}

func TestStoreFailKeepsLastFindings(t *testing.T) {
	s := newStore()
	s.set("trivy", []finding{{Severity: "high", Item: "img"}}, time.Now())
	s.fail("trivy")
	var b strings.Builder
	s.write(&b)
	if !strings.Contains(b.String(), `findings_open{source="trivy",severity="high",item="img"} 1`) ||
		!strings.Contains(b.String(), `findings_source_up{source="trivy"} 0`) {
		t.Errorf("a failed refresh must keep the last findings and mark the source down:\n%s", b.String())
	}
}
