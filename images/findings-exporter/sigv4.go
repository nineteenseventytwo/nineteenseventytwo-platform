package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

// credentials are temporary AWS credentials from STS.
type credentials struct {
	AccessKeyID     string
	SecretAccessKey string
	SessionToken    string
	Expiration      time.Time
}

// webIdentity exchanges the projected ServiceAccount token the
// pod-identity-webhook mounts (AWS_WEB_IDENTITY_TOKEN_FILE) for the role in
// AWS_ROLE_ARN, the same exchange every AWS SDK does. AssumeRoleWithWebIdentity
// is the one STS call that is not itself signed: the token is the credential.
type webIdentity struct {
	client    *http.Client
	region    string
	roleARN   string
	tokenFile string
	session   string

	mu     sync.Mutex
	cached credentials
}

func (w *webIdentity) get(ctx context.Context) (credentials, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.cached.AccessKeyID != "" && time.Until(w.cached.Expiration) > 5*time.Minute {
		return w.cached, nil
	}
	if w.roleARN == "" || w.tokenFile == "" {
		return credentials{}, fmt.Errorf("AWS_ROLE_ARN and AWS_WEB_IDENTITY_TOKEN_FILE must be set (is the ServiceAccount annotated?)")
	}
	// Re-read on every exchange: the kubelet rotates the projected token.
	token, err := os.ReadFile(w.tokenFile)
	if err != nil {
		return credentials{}, fmt.Errorf("web identity token: %w", err)
	}
	form := url.Values{
		"Action":           {"AssumeRoleWithWebIdentity"},
		"Version":          {"2011-06-15"},
		"RoleArn":          {w.roleARN},
		"RoleSessionName":  {w.session},
		"WebIdentityToken": {strings.TrimSpace(string(token))},
		"DurationSeconds":  {"3600"},
	}
	endpoint := fmt.Sprintf("https://sts.%s.amazonaws.com/", w.region)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return credentials{}, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := w.client.Do(req)
	if err != nil {
		return credentials{}, fmt.Errorf("sts: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if resp.StatusCode != http.StatusOK {
		return credentials{}, fmt.Errorf("sts: %s: %s", resp.Status, strings.TrimSpace(string(body)))
	}
	var parsed struct {
		Result struct {
			Credentials struct {
				AccessKeyID     string    `xml:"AccessKeyId"`
				SecretAccessKey string    `xml:"SecretAccessKey"`
				SessionToken    string    `xml:"SessionToken"`
				Expiration      time.Time `xml:"Expiration"`
			} `xml:"Credentials"`
		} `xml:"AssumeRoleWithWebIdentityResult"`
	}
	if err := xml.Unmarshal(body, &parsed); err != nil {
		return credentials{}, fmt.Errorf("sts response: %w", err)
	}
	c := parsed.Result.Credentials
	if c.AccessKeyID == "" {
		return credentials{}, fmt.Errorf("sts response had no credentials")
	}
	w.cached = credentials(c)
	return w.cached, nil
}

const emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

// signV4 signs a bodiless request for service in region, in place, with AWS
// Signature Version 4. It signs Host and every header already on the request,
// after adding x-amz-date, x-amz-content-sha256 and, for temporary
// credentials, x-amz-security-token. Only what S3 GETs need: no body hashing,
// no chunked uploads.
func signV4(req *http.Request, c credentials, region, service string, now time.Time) {
	amzDate := now.UTC().Format("20060102T150405Z")
	day := amzDate[:8]
	req.Header.Set("X-Amz-Date", amzDate)
	if req.Header.Get("X-Amz-Content-Sha256") == "" {
		req.Header.Set("X-Amz-Content-Sha256", emptySHA256)
	}
	if c.SessionToken != "" {
		req.Header.Set("X-Amz-Security-Token", c.SessionToken)
	}

	host := req.Host
	if host == "" {
		host = req.URL.Host
	}
	headers := map[string]string{"host": host}
	for k, v := range req.Header {
		headers[strings.ToLower(k)] = strings.Join(strings.Fields(strings.Join(v, ",")), " ")
	}
	names := make([]string, 0, len(headers))
	for k := range headers {
		names = append(names, k)
	}
	sort.Strings(names)
	var canonHeaders strings.Builder
	for _, k := range names {
		canonHeaders.WriteString(k + ":" + headers[k] + "\n")
	}
	signed := strings.Join(names, ";")

	canonical := strings.Join([]string{
		req.Method,
		canonicalPath(req.URL),
		canonicalQuery(req.URL.Query()),
		canonHeaders.String(),
		signed,
		req.Header.Get("X-Amz-Content-Sha256"),
	}, "\n")

	scope := day + "/" + region + "/" + service + "/aws4_request"
	toSign := "AWS4-HMAC-SHA256\n" + amzDate + "\n" + scope + "\n" + hexSHA256(canonical)

	key := hmacSHA256([]byte("AWS4"+c.SecretAccessKey), day)
	key = hmacSHA256(key, region)
	key = hmacSHA256(key, service)
	key = hmacSHA256(key, "aws4_request")
	sig := hex.EncodeToString(hmacSHA256(key, toSign))

	req.Header.Set("Authorization", fmt.Sprintf(
		"AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s",
		c.AccessKeyID, scope, signed, sig))
}

// canonicalPath URI-encodes each segment once. S3 does not double-encode.
func canonicalPath(u *url.URL) string {
	p := u.EscapedPath()
	if p == "" {
		return "/"
	}
	segs := strings.Split(p, "/")
	for i, s := range segs {
		if dec, err := url.PathUnescape(s); err == nil {
			segs[i] = awsEscape(dec)
		}
	}
	return strings.Join(segs, "/")
}

func canonicalQuery(q url.Values) string {
	keys := make([]string, 0, len(q))
	for k := range q {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var parts []string
	for _, k := range keys {
		vals := append([]string(nil), q[k]...)
		sort.Strings(vals)
		for _, v := range vals {
			parts = append(parts, awsEscape(k)+"="+awsEscape(v))
		}
	}
	return strings.Join(parts, "&")
}

// awsEscape is RFC 3986 percent-encoding: everything but A-Z a-z 0-9 - _ . ~.
func awsEscape(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if ('A' <= c && c <= 'Z') || ('a' <= c && c <= 'z') || ('0' <= c && c <= '9') ||
			c == '-' || c == '_' || c == '.' || c == '~' {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

func hexSHA256(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

func hmacSHA256(key []byte, data string) []byte {
	m := hmac.New(sha256.New, key)
	m.Write([]byte(data))
	return m.Sum(nil)
}
