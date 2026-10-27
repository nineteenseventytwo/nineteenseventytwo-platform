package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"time"
)

// alertmanagerSource reads Falco's and Kubescape's findings from the alerts
// they already send to Alertmanager. Active, unsilenced, uninhibited only: a
// silenced alert is a decision someone made, not an open finding.
type alertmanagerSource struct {
	client  *http.Client
	base    string
	sources []string // values of the `source` label to count
}

func (a *alertmanagerSource) names() []string { return a.sources }

type amAlert struct {
	Labels   map[string]string `json:"labels"`
	StartsAt time.Time         `json:"startsAt"`
}

func (a *alertmanagerSource) collect(ctx context.Context) (map[string][]finding, error) {
	q := url.Values{"active": {"true"}, "silenced": {"false"}, "inhibited": {"false"}}
	var alerts []amAlert
	if err := getJSON(ctx, a.client, strings.TrimRight(a.base, "/")+"/api/v2/alerts?"+q.Encode(), nil, &alerts); err != nil {
		return nil, fmt.Errorf("alertmanager: %w", err)
	}
	out := map[string][]finding{}
	for _, al := range alerts {
		src := al.Labels["source"]
		if !slices.Contains(a.sources, src) {
			continue
		}
		f := finding{Since: al.StartsAt}
		switch src {
		case "falco":
			// Falcosidekick's priority label carries Falco's own scale.
			f.Severity = normalizeSeverity(al.Labels["priority"])
			f.Item = al.Labels["rule"]
		case "kubescape":
			f.Severity = normalizeSeverity(al.Labels["severity"])
			f.Item = al.Labels["control"]
		default:
			f.Severity = normalizeSeverity(al.Labels["severity"])
			f.Item = al.Labels["alertname"]
		}
		out[src] = append(out[src], f)
	}
	return out, nil
}

// githubSource reads open code-scanning alerts: Trivy's weekly image scan
// and the lint workflow's Checkov and Trivy filesystem scans all upload
// there. auth is a GitHub App in the cluster, or a token file locally.
type githubSource struct {
	client *http.Client
	api    string
	repos  []string // owner/name
	tools  []string // lowercased tool names to report, e.g. trivy, checkov
	auth   tokenSource
}

func (g *githubSource) names() []string { return g.tools }

type ghAlert struct {
	CreatedAt time.Time `json:"created_at"`
	Rule      struct {
		ID                    string `json:"id"`
		Severity              string `json:"severity"`
		SecuritySeverityLevel string `json:"security_severity_level"`
	} `json:"rule"`
	Tool struct {
		Name string `json:"name"`
	} `json:"tool"`
	MostRecentInstance struct {
		Category string `json:"category"`
	} `json:"most_recent_instance"`
}

func (g *githubSource) collect(ctx context.Context) (map[string][]finding, error) {
	token, err := g.auth.token(ctx)
	if err != nil {
		return nil, err
	}
	headers := map[string]string{
		"Authorization":        "Bearer " + token,
		"Accept":               "application/vnd.github+json",
		"X-GitHub-Api-Version": "2022-11-28",
	}
	out := map[string][]finding{}
	for _, repo := range g.repos {
		next := fmt.Sprintf("%s/repos/%s/code-scanning/alerts?state=open&per_page=100", strings.TrimRight(g.api, "/"), repo)
		for next != "" {
			var page []ghAlert
			link, err := getJSONLink(ctx, g.client, next, headers, &page)
			if err != nil {
				return nil, fmt.Errorf("github %s: %w", repo, err)
			}
			for _, al := range page {
				tool := strings.ToLower(al.Tool.Name)
				if !slices.Contains(g.tools, tool) {
					continue
				}
				out[tool] = append(out[tool], ghFinding(al))
			}
			next = nextLink(link)
		}
	}
	return out, nil
}

// ghFinding prefers the CVSS-derived security severity (critical/high/...),
// which security tools set, over the generic error/warning/note level.
// Trivy's item is the scan category, which image-vuln-scan.yml sets to the
// image repository; everything else groups by rule.
func ghFinding(al ghAlert) finding {
	sev := al.Rule.SecuritySeverityLevel
	if sev == "" {
		sev = al.Rule.Severity
	}
	item := al.Rule.ID
	if strings.EqualFold(al.Tool.Name, "trivy") && al.MostRecentInstance.Category != "" {
		// image-vuln-scan.yml's category is the sanitised repository with
		// the tag stripped, which leaves a trailing "_".
		item = strings.TrimRight(al.MostRecentInstance.Category, "_")
	}
	return finding{Severity: normalizeSeverity(sev), Item: item, Since: al.CreatedAt}
}

// nextLink extracts rel="next" from a GitHub Link header.
func nextLink(header string) string {
	for _, part := range strings.Split(header, ",") {
		segs := strings.Split(part, ";")
		if len(segs) < 2 {
			continue
		}
		for _, s := range segs[1:] {
			if strings.TrimSpace(s) == `rel="next"` {
				return strings.Trim(strings.TrimSpace(segs[0]), "<>")
			}
		}
	}
	return ""
}

func getJSON(ctx context.Context, client *http.Client, u string, headers map[string]string, v any) error {
	_, err := getJSONLink(ctx, client, u, headers, v)
	return err
}

func getJSONLink(ctx context.Context, client *http.Client, u string, headers map[string]string, v any) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return "", err
	}
	for k, val := range headers {
		req.Header.Set(k, val)
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return "", fmt.Errorf("%s: %s", resp.Status, strings.TrimSpace(string(msg)))
	}
	return resp.Header.Get("Link"), json.NewDecoder(resp.Body).Decode(v)
}
