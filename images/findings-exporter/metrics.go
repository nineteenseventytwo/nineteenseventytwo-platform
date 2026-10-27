package main

import (
	"fmt"
	"io"
	"sort"
	"strings"
	"sync"
	"time"
)

// finding is one open finding, reduced to what the dashboard sorts by.
type finding struct {
	Severity string    // normalised: critical, high, medium, low, info, unknown
	Item     string    // the rule, control, image or check it belongs to
	Since    time.Time // when it was first seen open; zero if the source does not say
}

type sourceState struct {
	findings    []finding
	up          bool
	lastSuccess time.Time
	dataTime    time.Time // when the data itself was produced, where that differs
}

type store struct {
	mu      sync.Mutex
	sources map[string]*sourceState
}

func newStore() *store { return &store{sources: map[string]*sourceState{}} }

func (s *store) set(name string, fs []finding, now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	prev := s.sources[name]
	st := &sourceState{findings: fs, up: true, lastSuccess: now}
	if prev != nil {
		st.dataTime = prev.dataTime
	}
	s.sources[name] = st
}

func (s *store) setDataTime(name string, t time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if st, ok := s.sources[name]; ok {
		st.dataTime = t
	}
}

// fail keeps the last good findings but marks the source down. Dropping them
// would make a broken source read as a clean one.
func (s *store) fail(name string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	st, ok := s.sources[name]
	if !ok {
		st = &sourceState{}
		s.sources[name] = st
	}
	st.up = false
}

type countKey struct{ source, severity, item string }
type ageKey struct{ source, severity string }

func (s *store) write(w io.Writer) {
	s.mu.Lock()
	defer s.mu.Unlock()

	counts := map[countKey]int{}
	oldest := map[ageKey]time.Time{}
	names := make([]string, 0, len(s.sources))
	for name, st := range s.sources {
		names = append(names, name)
		for _, f := range st.findings {
			counts[countKey{name, f.Severity, f.Item}]++
			if !f.Since.IsZero() {
				k := ageKey{name, f.Severity}
				if o, ok := oldest[k]; !ok || f.Since.Before(o) {
					oldest[k] = f.Since
				}
			}
		}
	}
	sort.Strings(names)

	fmt.Fprintln(w, "# HELP findings_open Open findings by source, normalised severity and item (rule, control, image or check).")
	fmt.Fprintln(w, "# TYPE findings_open gauge")
	ck := make([]countKey, 0, len(counts))
	for k := range counts {
		ck = append(ck, k)
	}
	sort.Slice(ck, func(i, j int) bool {
		a, b := ck[i], ck[j]
		if a.source != b.source {
			return a.source < b.source
		}
		if a.severity != b.severity {
			return a.severity < b.severity
		}
		return a.item < b.item
	})
	for _, k := range ck {
		fmt.Fprintf(w, "findings_open{source=%s,severity=%s,item=%s} %d\n",
			quote(k.source), quote(k.severity), quote(k.item), counts[k])
	}

	fmt.Fprintln(w, "# HELP findings_oldest_open_timestamp_seconds When the oldest open finding was first seen, by source and severity.")
	fmt.Fprintln(w, "# TYPE findings_oldest_open_timestamp_seconds gauge")
	ak := make([]ageKey, 0, len(oldest))
	for k := range oldest {
		ak = append(ak, k)
	}
	sort.Slice(ak, func(i, j int) bool {
		if ak[i].source != ak[j].source {
			return ak[i].source < ak[j].source
		}
		return ak[i].severity < ak[j].severity
	})
	for _, k := range ak {
		fmt.Fprintf(w, "findings_oldest_open_timestamp_seconds{source=%s,severity=%s} %d\n",
			quote(k.source), quote(k.severity), oldest[k].Unix())
	}

	fmt.Fprintln(w, "# HELP findings_source_up 1 if the source's last refresh succeeded.")
	fmt.Fprintln(w, "# TYPE findings_source_up gauge")
	for _, n := range names {
		v := 0
		if s.sources[n].up {
			v = 1
		}
		fmt.Fprintf(w, "findings_source_up{source=%s} %d\n", quote(n), v)
	}

	fmt.Fprintln(w, "# HELP findings_source_last_success_timestamp_seconds When the source last refreshed successfully.")
	fmt.Fprintln(w, "# TYPE findings_source_last_success_timestamp_seconds gauge")
	for _, n := range names {
		if t := s.sources[n].lastSuccess; !t.IsZero() {
			fmt.Fprintf(w, "findings_source_last_success_timestamp_seconds{source=%s} %d\n", quote(n), t.Unix())
		}
	}
	s.writeDataTimes(w, names)
}

// writeDataTimes is split out only to keep write readable.
func (s *store) writeDataTimes(w io.Writer, names []string) {
	fmt.Fprintln(w, "# HELP findings_source_data_timestamp_seconds When the source's data was produced (the Prowler report's write time).")
	fmt.Fprintln(w, "# TYPE findings_source_data_timestamp_seconds gauge")
	for _, n := range names {
		if t := s.sources[n].dataTime; !t.IsZero() {
			fmt.Fprintf(w, "findings_source_data_timestamp_seconds{source=%s} %d\n", quote(n), t.Unix())
		}
	}
}

// labelEscaper escapes exactly what the text exposition format defines:
// backslash, double quote and newline. Go's %q is close but not the same - it
// also escapes tabs and non-printables, in forms the format does not define.
var labelEscaper = strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`)

func quote(s string) string {
	return `"` + labelEscaper.Replace(strings.ToValidUTF8(s, "")) + `"`
}
