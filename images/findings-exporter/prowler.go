package main

import (
	"context"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// prowlerSource reads the newest Prowler OCSF report from the findings bucket
// (nineteenseventytwo-cloud's prowler.yml writes one a day) and counts its
// unmuted FAILs by severity and check. It downloads a report only when a newer
// one has appeared, and stream-decodes it: a full scan is thousands of
// results, and this runs in 64Mi.
//
// Check IDs, not resource IDs, leave this process. Which resources fail is
// for the report in the bucket - the cloud repo keeps it out of its public
// logs for the same reason.
type prowlerSource struct {
	client *http.Client
	bucket string
	prefix string
	region string
	creds  interface {
		get(context.Context) (credentials, error)
	}
	now func() time.Time
	// endpoint overrides https://<bucket>.s3.<region>.amazonaws.com; tests only.
	endpoint string

	mu       sync.Mutex
	lastKey  string
	lastAt   time.Time
	lastFind []finding
}

// dataTimes reports when the newest report was written. Counts carried over
// from an old report look exactly like fresh ones; this is what tells them
// apart when the daily scan stops running.
func (p *prowlerSource) dataTimes() map[string]time.Time {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.lastAt.IsZero() {
		return nil
	}
	return map[string]time.Time{"prowler": p.lastAt}
}

func (p *prowlerSource) names() []string { return []string{"prowler"} }

func (p *prowlerSource) collect(ctx context.Context) (map[string][]finding, error) {
	c, err := p.creds.get(ctx)
	if err != nil {
		return nil, err
	}
	key, at, err := p.newestReport(ctx, c)
	if err != nil {
		return nil, err
	}
	p.mu.Lock()
	if key == p.lastKey {
		fs := p.lastFind
		p.mu.Unlock()
		return map[string][]finding{"prowler": fs}, nil
	}
	p.mu.Unlock()

	body, err := p.get(ctx, c, "/"+key, nil)
	if err != nil {
		return nil, err
	}
	defer body.Close()
	fs, err := parseOCSF(body)
	if err != nil {
		return nil, fmt.Errorf("prowler %s: %w", key, err)
	}

	p.mu.Lock()
	p.lastKey, p.lastAt, p.lastFind = key, at, fs
	p.mu.Unlock()
	return map[string][]finding{"prowler": fs}, nil
}

type listResult struct {
	Contents []struct {
		Key          string    `xml:"Key"`
		LastModified time.Time `xml:"LastModified"`
	} `xml:"Contents"`
	IsTruncated           bool   `xml:"IsTruncated"`
	NextContinuationToken string `xml:"NextContinuationToken"`
}

// newestReport pages through the prefix and returns the most recently
// written *.ocsf.json. The bucket expires objects after 180 days, so the
// listing stays a few hundred keys.
func (p *prowlerSource) newestReport(ctx context.Context, c credentials) (string, time.Time, error) {
	var newest string
	var newestAt time.Time
	token := ""
	for {
		q := url.Values{"list-type": {"2"}, "prefix": {p.prefix}}
		if token != "" {
			q.Set("continuation-token", token)
		}
		body, err := p.get(ctx, c, "/", q)
		if err != nil {
			return "", time.Time{}, err
		}
		var page listResult
		err = xml.NewDecoder(body).Decode(&page)
		body.Close()
		if err != nil {
			return "", time.Time{}, fmt.Errorf("list %s: %w", p.bucket, err)
		}
		for _, o := range page.Contents {
			if strings.HasSuffix(o.Key, ".ocsf.json") && o.LastModified.After(newestAt) {
				newest, newestAt = o.Key, o.LastModified
			}
		}
		if !page.IsTruncated || page.NextContinuationToken == "" {
			break
		}
		token = page.NextContinuationToken
	}
	if newest == "" {
		return "", time.Time{}, fmt.Errorf("no *.ocsf.json under s3://%s/%s", p.bucket, p.prefix)
	}
	return newest, newestAt, nil
}

func (p *prowlerSource) get(ctx context.Context, c credentials, path string, q url.Values) (io.ReadCloser, error) {
	u := &url.URL{
		Scheme:   "https",
		Host:     fmt.Sprintf("%s.s3.%s.amazonaws.com", p.bucket, p.region),
		Path:     path,
		RawQuery: q.Encode(),
	}
	if p.endpoint != "" {
		base, err := url.Parse(p.endpoint)
		if err != nil {
			return nil, err
		}
		u.Scheme, u.Host = base.Scheme, base.Host
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, err
	}
	now := time.Now
	if p.now != nil {
		now = p.now
	}
	signV4(req, c, p.region, "s3", now())
	resp, err := p.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("s3 %s: %w", path, err)
	}
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		resp.Body.Close()
		return nil, fmt.Errorf("s3 %s: %s: %s", path, resp.Status, strings.TrimSpace(string(msg)))
	}
	return resp.Body, nil
}

// ocsfFinding is the slice of a Prowler OCSF result this needs. Muted
// findings (prowler/mutelist.yaml in the cloud repo) carry status
// "Suppressed": decisions, not open findings - the same rule prowler.yml's
// own summary applies.
type ocsfFinding struct {
	StatusCode string `json:"status_code"`
	Status     string `json:"status"`
	Severity   string `json:"severity"`
	Metadata   struct {
		EventCode string `json:"event_code"`
	} `json:"metadata"`
}

// parseOCSF stream-decodes a top-level JSON array of OCSF findings.
func parseOCSF(r io.Reader) ([]finding, error) {
	dec := json.NewDecoder(r)
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	if d, ok := tok.(json.Delim); !ok || d != '[' {
		return nil, fmt.Errorf("want a JSON array, got %v", tok)
	}
	var out []finding
	for dec.More() {
		var f ocsfFinding
		if err := dec.Decode(&f); err != nil {
			return nil, err
		}
		if f.StatusCode != "FAIL" || f.Status == "Suppressed" {
			continue
		}
		// No Since: a report's timestamps are the scan's, not when a finding
		// first appeared, and an age that resets daily would mislead.
		out = append(out, finding{Severity: normalizeSeverity(f.Severity), Item: f.Metadata.EventCode})
	}
	if _, err := dec.Token(); err != nil {
		return nil, err
	}
	return out, nil
}
