// findings-exporter puts every security finding source this platform has into
// one set of Prometheus metrics, for one Grafana view (07 Phase 10.4).
//
//	falco, kubescape   active alerts in Alertmanager (10.1, 10.2)
//	trivy, checkov     open code-scanning alerts on GitHub (image-vuln-scan.yml, lint.yml)
//	prowler            the newest scan's unmuted FAILs, from the findings bucket in S3
//
// Counts, not detail: each source is reduced to open findings by severity and
// by one identifying item (Falco rule, Kubescape control, image, Prowler
// check). The detail stays where it already lives - Slack, the Security tab,
// the bucket's HTML report. Prioritisation is the point of the view, and it
// needs severity, source and age, not CVE text.
//
// Each source refreshes on its own interval in the background, so a slow or
// failing source never blocks a scrape or the others. findings_source_up says
// which ones answered last time: a source that has silently stopped reporting
// must not look like a source with nothing to report.
//
// No client libraries - the AWS calls (one STS, two S3) are signed by hand in
// sigv4.go. Same reasoning as dash: every dependency is something the weekly
// image scan has to say something about.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	store := newStore()
	client := &http.Client{Timeout: 60 * time.Second}
	ctx := context.Background()

	if am := os.Getenv("FINDINGS_ALERTMANAGER"); am != "" {
		src := &alertmanagerSource{
			client:  client,
			base:    am,
			sources: splitList(env("FINDINGS_ALERTMANAGER_SOURCES", "falco,kubescape")),
		}
		go poll(ctx, logger, store, src, every("FINDINGS_ALERTMANAGER_EVERY", time.Minute))
	}
	if repos := splitList(os.Getenv("FINDINGS_GITHUB_REPOS")); len(repos) > 0 {
		api := env("FINDINGS_GITHUB_API", "https://api.github.com")
		var auth tokenSource = fileToken{path: env("FINDINGS_GITHUB_TOKEN_FILE", "/secrets/github/token")}
		// The App's credentials are three files from one Secret: the two IDs
		// are not secret, but files keep them out of the pod spec's env.
		if dir := os.Getenv("FINDINGS_GITHUB_APP_DIR"); dir != "" {
			appID, err1 := readTrimmed(filepath.Join(dir, "app-id"))
			instID, err2 := readTrimmed(filepath.Join(dir, "installation-id"))
			if err := errors.Join(err1, err2); err != nil {
				logger.Error("github app credentials", "err", err)
				os.Exit(1)
			}
			auth = &githubApp{
				client:         client,
				api:            api,
				appID:          appID,
				installationID: instID,
				keyFile:        filepath.Join(dir, "private-key"),
			}
		}
		src := &githubSource{
			client: client,
			api:    api,
			repos:  repos,
			tools:  splitList(env("FINDINGS_GITHUB_TOOLS", "trivy,checkov")),
			auth:   auth,
		}
		go poll(ctx, logger, store, src, every("FINDINGS_GITHUB_EVERY", 15*time.Minute))
	}
	if bucket := os.Getenv("FINDINGS_PROWLER_BUCKET"); bucket != "" {
		region := env("AWS_REGION", "eu-west-2")
		src := &prowlerSource{
			client: client,
			bucket: bucket,
			prefix: env("FINDINGS_PROWLER_PREFIX", "findings/"),
			region: region,
			creds: &webIdentity{
				client:    client,
				region:    region,
				roleARN:   os.Getenv("AWS_ROLE_ARN"),
				tokenFile: os.Getenv("AWS_WEB_IDENTITY_TOKEN_FILE"),
				session:   "findings-exporter",
			},
		}
		go poll(ctx, logger, store, src, every("FINDINGS_PROWLER_EVERY", time.Hour))
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /metrics", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		store.write(w)
	})
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok\n"))
	})
	srv := &http.Server{
		Addr:              env("FINDINGS_LISTEN", ":8080"),
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		WriteTimeout:      10 * time.Second,
	}
	logger.Info("listening", "addr", srv.Addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Error("server stopped", "err", err)
		os.Exit(1)
	}
}

// source is one collector. It reports under fixed names, declared up front
// (GitHub reports one per scanning tool), so that when a call fails every
// name it would have filled is marked down - not a separate "github" entry
// the dashboard never shows next to trivy.
type source interface {
	names() []string
	collect(ctx context.Context) (map[string][]finding, error)
}

func poll(ctx context.Context, logger *slog.Logger, store *store, src source, interval time.Duration) {
	for {
		cctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
		results, err := src.collect(cctx)
		cancel()
		if err != nil {
			logger.Error("collect failed", "sources", src.names(), "err", err)
			for _, n := range src.names() {
				store.fail(n)
			}
		} else {
			for _, name := range src.names() {
				store.set(name, results[name], time.Now())
				logger.Info("collected", "source", name, "findings", len(results[name]))
			}
			if dt, ok := src.(interface{ dataTimes() map[string]time.Time }); ok {
				for name, t := range dt.dataTimes() {
					store.setDataTime(name, t)
				}
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(interval):
		}
	}
}

// normalizeSeverity maps each tool's vocabulary onto one scale, so a
// dashboard can sort across sources. Unknown values become "unknown" rather
// than being guessed into a bucket.
func normalizeSeverity(s string) string {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "critical", "emergency", "alert", "fatal":
		return "critical"
	case "high", "error":
		return "high"
	case "medium", "warning", "moderate":
		return "medium"
	case "low", "notice", "note":
		return "low"
	case "informational", "info", "debug":
		return "info"
	default:
		return "unknown"
	}
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func every(key string, fallback time.Duration) time.Duration {
	if d, err := time.ParseDuration(os.Getenv(key)); err == nil && d > 0 {
		return d
	}
	return fallback
}

func readTrimmed(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(b)), nil
}

func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}
