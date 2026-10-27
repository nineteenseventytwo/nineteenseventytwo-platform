// kubescape-gate turns a Kubescape scan into "what changed" (07 Phase 10.2).
//
// ADR-0017 decided that a scan is clean when its failures match a reviewed
// list, not when its score clears a number. This is that comparison, run
// nightly by cluster/kubescape's CronJob after Kubescape writes its JSON:
//
//   - a failing (control, resource) pair that is not in the accepted list is a
//     regression, and is sent to Alertmanager, one alert per control
//   - an accepted pair that no longer fails is stale, and is only logged, so
//     the list can be pruned in a PR
//
// Exit 0 means the comparison ran, regressions or not: the alert is the
// signal for those. Exit 1 means it could not run (no scan, an empty scan, an
// unreadable list, Alertmanager refusing the alert), which fails the Job and
// fires the kube-prometheus KubeJobFailed alert instead. A gate that silently
// stops running would look exactly like a clean cluster.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strings"
	"time"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	cfg := config{
		ScanPath:     env("GATE_SCAN", "/scan/results.json"),
		AcceptedPath: env("GATE_ACCEPTED", "/accepted/accepted.txt"),
		Alertmanager: os.Getenv("GATE_ALERTMANAGER"),
		Expire:       25 * time.Hour,
	}
	if err := run(cfg, logger, http.DefaultClient, time.Now()); err != nil {
		logger.Error("gate failed", "err", err)
		os.Exit(1)
	}
}

type config struct {
	ScanPath     string
	AcceptedPath string
	// Empty means log only. The CronJob always sets it.
	Alertmanager string
	// Long enough to stay firing until the next nightly run, which either
	// re-sends it or lets it lapse once the regression is fixed or accepted.
	Expire time.Duration
}

func run(cfg config, logger *slog.Logger, client *http.Client, now time.Time) error {
	scanFile, err := os.Open(cfg.ScanPath)
	if err != nil {
		return fmt.Errorf("open scan: %w", err)
	}
	defer scanFile.Close()
	failing, names, err := parseScan(scanFile)
	if err != nil {
		return err
	}

	acceptedFile, err := os.Open(cfg.AcceptedPath)
	if err != nil {
		return fmt.Errorf("open accepted list: %w", err)
	}
	defer acceptedFile.Close()
	accepted, err := parseAccepted(acceptedFile)
	if err != nil {
		return err
	}

	regressions := difference(failing, accepted)
	stale := difference(accepted, failing)
	logger.Info("compared",
		"failing", len(failing), "accepted", len(accepted),
		"regressions", len(regressions), "stale", len(stale))
	for _, p := range regressions {
		logger.Warn("regression", "control", p.Control, "name", names[p.Control], "resource", p.Resource)
	}
	for _, p := range stale {
		logger.Info("stale", "control", p.Control, "resource", p.Resource)
	}

	if len(regressions) == 0 || cfg.Alertmanager == "" {
		return nil
	}
	return postAlerts(client, cfg.Alertmanager, buildAlerts(regressions, names, now, cfg.Expire))
}

// pair is one control failing on one resource, with the resource reduced to
// namespace/Kind/name (namespace empty for cluster-scoped objects).
type pair struct {
	Control  string
	Resource string
}

func (p pair) String() string { return p.Control + " " + p.Resource }

// Hex runs of eight or more are generated names: Longhorn's
// instance-manager-<32 hex>, ARC's listener <8 hex>. Without this every
// upgrade that renames them would read as a new finding.
var generated = regexp.MustCompile(`[0-9a-f]{8,}`)

// normalize reduces a Kubescape resourceID to namespace/Kind/name. RBAC
// results chain several objects into one ID (ServiceAccount, Role,
// RoleBinding); the last three segments are the binding, which is the object
// that grants.
func normalize(resourceID string) string {
	parts := strings.Split(resourceID, "/")
	if len(parts) > 3 {
		parts = parts[len(parts)-3:]
	}
	parts[len(parts)-1] = generated.ReplaceAllString(parts[len(parts)-1], "*")
	return strings.Join(parts, "/")
}

type scanResult struct {
	Results []struct {
		ResourceID string `json:"resourceID"`
		Controls   []struct {
			ControlID string `json:"controlID"`
			Name      string `json:"name"`
			Status    struct {
				Status string `json:"status"`
			} `json:"status"`
		} `json:"controls"`
	} `json:"results"`
}

// parseScan returns the failing pairs and each control's name.
func parseScan(r io.Reader) (map[pair]bool, map[string]string, error) {
	var scan scanResult
	if err := json.NewDecoder(r).Decode(&scan); err != nil {
		return nil, nil, fmt.Errorf("decode scan: %w", err)
	}
	// A scan with no results did not scan anything (no API access, a
	// framework that failed to download). Treating it as clean is the one
	// mistake this gate must not make.
	if len(scan.Results) == 0 {
		return nil, nil, fmt.Errorf("scan has no results")
	}
	failing := map[pair]bool{}
	names := map[string]string{}
	for _, res := range scan.Results {
		for _, c := range res.Controls {
			names[c.ControlID] = c.Name
			if c.Status.Status == "failed" {
				failing[pair{c.ControlID, normalize(res.ResourceID)}] = true
			}
		}
	}
	return failing, names, nil
}

// parseAccepted reads the reviewed list: one "C-NNNN namespace/Kind/name" per
// line, # starts a comment. Reasons live in the comments and in ADR-0017.
func parseAccepted(r io.Reader) (map[pair]bool, error) {
	accepted := map[pair]bool{}
	sc := bufio.NewScanner(r)
	line := 0
	for sc.Scan() {
		line++
		text, _, _ := strings.Cut(sc.Text(), "#")
		fields := strings.Fields(text)
		switch len(fields) {
		case 0:
			continue
		case 2:
			if !strings.HasPrefix(fields[0], "C-") {
				return nil, fmt.Errorf("accepted list line %d: %q is not a control ID", line, fields[0])
			}
			accepted[pair{fields[0], fields[1]}] = true
		default:
			return nil, fmt.Errorf("accepted list line %d: want \"C-NNNN namespace/Kind/name\", got %q", line, sc.Text())
		}
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("read accepted list: %w", err)
	}
	return accepted, nil
}

// difference returns the pairs in a that are not in b, sorted.
func difference(a, b map[pair]bool) []pair {
	var out []pair
	for p := range a {
		if !b[p] {
			out = append(out, p)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].String() < out[j].String() })
	return out
}

type alert struct {
	Labels      map[string]string `json:"labels"`
	Annotations map[string]string `json:"annotations"`
	StartsAt    time.Time         `json:"startsAt"`
	EndsAt      time.Time         `json:"endsAt"`
}

// buildAlerts makes one alert per control, listing its new resources. Per
// control rather than per resource: one new chart that fails five controls
// on ten objects is five messages, not fifty.
func buildAlerts(regressions []pair, names map[string]string, now time.Time, expire time.Duration) []alert {
	byControl := map[string][]string{}
	var controls []string
	for _, p := range regressions {
		if _, seen := byControl[p.Control]; !seen {
			controls = append(controls, p.Control)
		}
		byControl[p.Control] = append(byControl[p.Control], p.Resource)
	}
	alerts := make([]alert, 0, len(controls))
	for _, c := range controls {
		resources := byControl[c]
		alerts = append(alerts, alert{
			Labels: map[string]string{
				"alertname": "KubescapeRegression",
				"source":    "kubescape",
				"severity":  "warning",
				"control":   c,
			},
			Annotations: map[string]string{
				"summary": fmt.Sprintf("%s %s: %d resource(s) newly failing", c, names[c], len(resources)),
				"description": strings.Join(resources, "\n") +
					"\nFix it, or add it to cluster/kubescape/00-accepted.yaml with its reason (ADR-0017).",
			},
			StartsAt: now,
			EndsAt:   now.Add(expire),
		})
	}
	return alerts
}

func postAlerts(client *http.Client, base string, alerts []alert) error {
	body, err := json.Marshal(alerts)
	if err != nil {
		return err
	}
	url := strings.TrimRight(base, "/") + "/api/v2/alerts"
	resp, err := client.Post(url, "application/json", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("post alerts: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("post alerts: %s: %s", resp.Status, msg)
	}
	return nil
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
