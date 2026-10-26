// dash renders the state of the eightbitsaxlounge services, for
// dash.eightbitsaxlounge.com behind Cloudflare Access (ADR-0018 W5, ADR-0021).
//
// It reads Deployments, StatefulSets and Pods in a fixed list of namespaces
// with its own ServiceAccount, and nothing else: the Role it holds is
// get/list/watch in those namespaces only (policy/42-dash.yaml). No client-go -
// three GETs do not justify the dependency tree, and every dependency is
// something the weekly image scan has to say something about.
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

const saDir = "/var/run/secrets/kubernetes.io/serviceaccount"

//go:embed templates/index.html static/style.css
var assets embed.FS

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	cfg := config{
		Namespaces: splitList(env("DASH_NAMESPACES", "eightbitsaxlounge-prod,eightbitsaxlounge-dev")),
		Selector:   env("DASH_SELECTOR", "app=eightbitsaxlounge"),
		Components: splitList(env("DASH_COMPONENTS", "db,state,data,midi,overlay,chat")),
	}

	api, err := inClusterAPI()
	if err != nil {
		logger.Error("no in-cluster API config", "err", err)
		os.Exit(1)
	}

	srv := newServer(cfg, api, logger)
	httpServer := &http.Server{
		Addr:              env("DASH_LISTEN", ":8080"),
		Handler:           srv.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      20 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	logger.Info("listening", "addr", httpServer.Addr, "namespaces", cfg.Namespaces)
	if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Error("server stopped", "err", err)
		os.Exit(1)
	}
}

type config struct {
	Namespaces []string
	Selector   string
	Components []string
}

// apiClient is the whole of this program's Kubernetes surface: authenticated
// GETs against the API server, decoded into whatever the caller passes.
type apiClient struct {
	base      string
	http      *http.Client
	tokenPath string
}

func inClusterAPI() (*apiClient, error) {
	host, port := os.Getenv("KUBERNETES_SERVICE_HOST"), os.Getenv("KUBERNETES_SERVICE_PORT")
	if host == "" || port == "" {
		return nil, errors.New("KUBERNETES_SERVICE_HOST/PORT unset - not running in a pod")
	}
	ca, err := os.ReadFile(saDir + "/ca.crt")
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(ca) {
		return nil, errors.New("ca.crt holds no certificates")
	}
	return &apiClient{
		base: "https://" + net.JoinHostPort(host, port),
		http: &http.Client{
			Timeout:   5 * time.Second,
			Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}},
		},
		tokenPath: saDir + "/token",
	}, nil
}

func (c *apiClient) get(ctx context.Context, path string, query url.Values, out any) error {
	// Re-read on every call: the projected token rotates underneath the pod,
	// and a token cached at startup stops working about an hour in.
	token, err := os.ReadFile(c.tokenPath)
	if err != nil {
		return err
	}
	u := c.base + path
	if len(query) > 0 {
		u += "?" + query.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(token)))
	req.Header.Set("Accept", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GET %s: %s", path, resp.Status)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// The few fields of each kind this program reads. Deployments and
// StatefulSets share the shape that matters here.
type workloadList struct {
	Items []struct {
		Metadata struct {
			Labels map[string]string `json:"labels"`
		} `json:"metadata"`
		Spec struct {
			Replicas *int32 `json:"replicas"`
		} `json:"spec"`
		Status struct {
			ReadyReplicas int32 `json:"readyReplicas"`
		} `json:"status"`
	} `json:"items"`
}

type podList struct {
	Items []struct {
		Metadata struct {
			Labels map[string]string `json:"labels"`
		} `json:"metadata"`
		Status struct {
			ContainerStatuses []struct {
				RestartCount int32 `json:"restartCount"`
				State        struct {
					Waiting *struct {
						Reason string `json:"reason"`
					} `json:"waiting"`
				} `json:"state"`
			} `json:"containerStatuses"`
		} `json:"status"`
	} `json:"items"`
}

// State is what a row says. Unknown is a real state, not an empty row:
// when the API cannot be read, the page has to say so (09 W5).
type State string

const (
	Running  State = "running"
	Degraded State = "degraded"
	Crashing State = "crashing"
	Stopped  State = "stopped"
	Unknown  State = "unknown"
)

// crashReasons are the waiting reasons that mean "will not come up on its
// own", as opposed to ContainerCreating or PodInitializing, which mean "not
// up yet".
var crashReasons = map[string]bool{
	"CrashLoopBackOff":           true,
	"ImagePullBackOff":           true,
	"ErrImagePull":               true,
	"CreateContainerConfigError": true,
	"CreateContainerError":       true,
	"RunContainerError":          true,
	"InvalidImageName":           true,
}

type Row struct {
	Component string
	State     State
	Ready     int32
	Desired   int32
	Restarts  int32
	Note      string
}

type NamespaceView struct {
	Name  string
	Rows  []Row
	Error string
}

// classify turns one component's workload and pods into a row. found is false
// when no Deployment or StatefulSet carries the component label at all.
func classify(component string, found bool, desired, ready int32, waitingReasons []string, restarts int32) Row {
	row := Row{Component: component, Desired: desired, Ready: ready, Restarts: restarts}
	switch {
	case !found:
		row.State, row.Note = Unknown, "no workload found"
	case desired == 0:
		row.State = Stopped
	case len(waitingReasons) > 0:
		row.State, row.Note = Crashing, strings.Join(waitingReasons, ", ")
	case ready >= desired:
		row.State = Running
	default:
		row.State = Degraded
	}
	return row
}

func (s *server) namespaceView(ctx context.Context, ns string) NamespaceView {
	view := NamespaceView{Name: ns}
	unknown := func(err error) NamespaceView {
		s.log.Warn("namespace unreadable", "namespace", ns, "err", err)
		view.Error = "cluster API unreachable or refused - state unknown"
		view.Rows = view.Rows[:0]
		for _, c := range s.cfg.Components {
			view.Rows = append(view.Rows, Row{Component: c, State: Unknown})
		}
		return view
	}

	q := url.Values{"labelSelector": {s.cfg.Selector}}
	var deps, sets workloadList
	var pods podList
	if err := s.api.get(ctx, "/apis/apps/v1/namespaces/"+url.PathEscape(ns)+"/deployments", q, &deps); err != nil {
		return unknown(err)
	}
	if err := s.api.get(ctx, "/apis/apps/v1/namespaces/"+url.PathEscape(ns)+"/statefulsets", q, &sets); err != nil {
		return unknown(err)
	}
	if err := s.api.get(ctx, "/api/v1/namespaces/"+url.PathEscape(ns)+"/pods", q, &pods); err != nil {
		return unknown(err)
	}

	for _, comp := range s.cfg.Components {
		found := false
		var desired, ready int32
		for _, list := range []workloadList{deps, sets} {
			for _, w := range list.Items {
				if w.Metadata.Labels["component"] != comp {
					continue
				}
				found = true
				if w.Spec.Replicas != nil {
					desired += *w.Spec.Replicas
				} else {
					desired++ // the API server's default
				}
				ready += w.Status.ReadyReplicas
			}
		}
		var reasons []string
		var restarts int32
		seen := map[string]bool{}
		for _, p := range pods.Items {
			if p.Metadata.Labels["component"] != comp {
				continue
			}
			for _, cs := range p.Status.ContainerStatuses {
				restarts += cs.RestartCount
				if w := cs.State.Waiting; w != nil && crashReasons[w.Reason] && !seen[w.Reason] {
					seen[w.Reason] = true
					reasons = append(reasons, w.Reason)
				}
			}
		}
		view.Rows = append(view.Rows, classify(comp, found, desired, ready, reasons, restarts))
	}
	return view
}

type server struct {
	cfg  config
	api  *apiClient
	log  *slog.Logger
	page *template.Template
	css  []byte
}

func newServer(cfg config, api *apiClient, logger *slog.Logger) *server {
	css, err := assets.ReadFile("static/style.css")
	if err != nil {
		panic(err) // embedded at build time; absence is a build bug
	}
	return &server{
		cfg:  cfg,
		api:  api,
		log:  logger,
		page: template.Must(template.ParseFS(assets, "templates/index.html")),
		css:  css,
	}
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", s.index)
	mux.HandleFunc("GET /style.css", s.style)
	// Answers without touching the API server, so a probe failure means this
	// process is broken - not that the cluster API is slow.
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})
	return securityHeaders(mux)
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		// No script at all, and only this origin's stylesheet. The page
		// refreshes with <meta http-equiv="refresh">, which CSP does not govern.
		h.Set("Content-Security-Policy", "default-src 'none'; style-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}

type pageData struct {
	Generated  string
	Viewer     string
	Namespaces []NamespaceView
}

func (s *server) index(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	// Set by Cloudflare Access on every request that passed it. cloudflared
	// has already validated the JWT before the request gets here (ADR-0021);
	// this is for the log and the page, not for authorisation.
	viewer := r.Header.Get("Cf-Access-Authenticated-User-Email")
	s.log.Info("view", "viewer", viewer)

	data := pageData{Generated: time.Now().UTC().Format("2006-01-02 15:04:05 UTC"), Viewer: viewer}
	for _, ns := range s.cfg.Namespaces {
		data.Namespaces = append(data.Namespaces, s.namespaceView(ctx, ns))
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := s.page.Execute(w, data); err != nil {
		s.log.Error("render", "err", err)
	}
}

func (s *server) style(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/css; charset=utf-8")
	_, _ = w.Write(s.css)
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func splitList(s string) []string {
	var out []string
	for _, part := range strings.Split(s, ",") {
		if p := strings.TrimSpace(part); p != "" {
			out = append(out, p)
		}
	}
	return out
}
