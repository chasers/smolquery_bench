// tsbsrw loads a TSBS data file into a Prometheus remote write endpoint. It
// reads the Influx line protocol that `tsbs_generate_data
// -format=victoriametrics` writes, names every field `<measurement>_<field>`
// as VictoriaMetrics names an Influx field, and turns each field of each
// line into one series with one sample, its tags as labels. -samples samples
// make one WriteRequest, protobuf encoded and snappy framed as remote write
// 1.0, posted by one of -workers goroutines, round-robin across -urls.
//
// A retry re-sends the same bytes, so an edge that keys a block by its hash
// answers it from the first commit. A 429 or 503 is retried after its
// retry-after for as long as it takes, as vmagent retries it. Any other 5xx
// or a dropped connection is retried with backoff up to 30 times. A 400, 401,
// 413 or 415 is not retried: its samples count as rejected. The
// authorization header value comes from the AUTH environment variable, never
// from the command line.
package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/golang/snappy"
)

const (
	maxAttempts   = 30
	maxRetryAfter = 5 * time.Second
	progressEvery = 5 * time.Second
)

type batch struct {
	index   int
	raw     []byte
	samples int64
}

type stats struct {
	mu              sync.Mutex
	latenciesMs     []float64
	linesRead       atomic.Int64
	samplesRead     atomic.Int64
	samplesAccepted atomic.Int64
	samplesRejected atomic.Int64
	samplesFailed   atomic.Int64
	bytesSent       atomic.Int64
	bytesDecoded    atomic.Int64
	requests        atomic.Int64
	retriesBusy     atomic.Int64
	retriesOther    atomic.Int64
	minTsMs         atomic.Int64
	maxTsMs         atomic.Int64
	statuses        map[int]int64
	lastDoneAt      atomic.Int64
	stoppedEarly    atomic.Bool
}

type label struct {
	name  []byte
	value []byte
}

func pastDeadline(deadline time.Time) bool {
	return !deadline.IsZero() && time.Now().After(deadline)
}

func clientCPUSeconds() float64 {
	var usage syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &usage); err != nil {
		return 0
	}
	return float64(usage.Utime.Sec) + float64(usage.Utime.Usec)/1e6 +
		float64(usage.Stime.Sec) + float64(usage.Stime.Usec)/1e6
}

func (s *stats) recordStatus(code int) {
	s.mu.Lock()
	s.statuses[code]++
	s.mu.Unlock()
}

func (s *stats) recordLatency(ms float64) {
	s.mu.Lock()
	s.latenciesMs = append(s.latenciesMs, ms)
	s.mu.Unlock()
}

func (s *stats) recordTs(ms int64) {
	for {
		cur := s.minTsMs.Load()
		if (cur != 0 && cur <= ms) || s.minTsMs.CompareAndSwap(cur, ms) {
			break
		}
	}
	for {
		cur := s.maxTsMs.Load()
		if cur >= ms || s.maxTsMs.CompareAndSwap(cur, ms) {
			break
		}
	}
}

func fieldCount(line []byte) int64 {
	first := bytes.IndexByte(line, ' ')
	if first < 0 {
		return 0
	}
	rest := line[first+1:]
	second := bytes.IndexByte(rest, ' ')
	if second < 0 {
		return 0
	}
	return int64(bytes.Count(rest[:second], []byte{','}) + 1)
}

func appendVarint(buf []byte, v uint64) []byte {
	return binary.AppendUvarint(buf, v)
}

func appendBytesField(buf []byte, tag byte, value []byte) []byte {
	buf = append(buf, tag)
	buf = appendVarint(buf, uint64(len(value)))
	return append(buf, value...)
}

func labelLen(l label) int {
	n := len(l.name)
	v := len(l.value)
	return 1 + varintLen(n) + n + 1 + varintLen(v) + v
}

func varintLen(n int) int {
	size := 1
	for n >= 0x80 {
		n >>= 7
		size++
	}
	return size
}

func appendSeries(buf []byte, labels []label, value float64, tsMs int64) []byte {
	sample := make([]byte, 0, 20)
	sample = append(sample, 0x09)
	sample = binary.LittleEndian.AppendUint64(sample, math.Float64bits(value))
	sample = append(sample, 0x10)
	sample = appendVarint(sample, uint64(tsMs))

	seriesLen := 1 + varintLen(len(sample)) + len(sample)
	for _, l := range labels {
		n := labelLen(l)
		seriesLen += 1 + varintLen(n) + n
	}

	buf = append(buf, 0x0a)
	buf = appendVarint(buf, uint64(seriesLen))
	for _, l := range labels {
		buf = append(buf, 0x0a)
		buf = appendVarint(buf, uint64(labelLen(l)))
		buf = appendBytesField(buf, 0x0a, l.name)
		buf = appendBytesField(buf, 0x12, l.value)
	}
	return appendBytesField(buf, 0x12, sample)
}

func parseValue(raw []byte) (float64, bool) {
	if n := len(raw); n > 0 && (raw[n-1] == 'i' || raw[n-1] == 'u') {
		raw = raw[:n-1]
	}
	v, err := strconv.ParseFloat(string(raw), 64)
	return v, err == nil
}

func encode(raw []byte, st *stats) ([]byte, int64, error) {
	out := make([]byte, 0, len(raw)*3)
	var samples int64
	labels := make([]label, 0, 16)
	for len(raw) > 0 {
		nl := bytes.IndexByte(raw, '\n')
		var line []byte
		if nl < 0 {
			line, raw = raw, nil
		} else {
			line, raw = raw[:nl], raw[nl+1:]
		}
		if len(line) == 0 || line[0] == '#' {
			continue
		}
		parts := bytes.SplitN(line, []byte{' '}, 3)
		if len(parts) != 3 {
			return nil, 0, fmt.Errorf("line has %d space-separated parts, want 3: %q", len(parts), line)
		}
		tsNs, err := strconv.ParseInt(string(bytes.TrimSpace(parts[2])), 10, 64)
		if err != nil {
			return nil, 0, fmt.Errorf("timestamp: %w in %q", err, line)
		}
		tsMs := tsNs / 1_000_000
		st.recordTs(tsMs)

		tags := bytes.Split(parts[0], []byte{','})
		measurement := tags[0]
		labels = labels[:0]
		labels = append(labels, label{name: []byte("__name__")})
		for _, tag := range tags[1:] {
			eq := bytes.IndexByte(tag, '=')
			if eq < 0 {
				return nil, 0, fmt.Errorf("tag without '=': %q", tag)
			}
			labels = append(labels, label{name: tag[:eq], value: tag[eq+1:]})
		}
		sort.Slice(labels, func(i, j int) bool { return bytes.Compare(labels[i].name, labels[j].name) < 0 })
		nameAt := 0
		for i, l := range labels {
			if string(l.name) == "__name__" {
				nameAt = i
			}
		}

		for _, field := range bytes.Split(parts[1], []byte{','}) {
			eq := bytes.IndexByte(field, '=')
			if eq < 0 {
				return nil, 0, fmt.Errorf("field without '=': %q", field)
			}
			value, ok := parseValue(field[eq+1:])
			if !ok {
				continue
			}
			name := make([]byte, 0, len(measurement)+1+eq)
			name = append(name, measurement...)
			name = append(name, '_')
			name = append(name, field[:eq]...)
			labels[nameAt].value = name
			out = appendSeries(out, labels, value, tsMs)
			samples++
		}
	}
	return out, samples, nil
}

func readBatches(path string, targetSamples int64, maxSamples int64, deadline time.Time, jobs chan<- batch, st *stats) {
	defer close(jobs)
	f, err := os.Open(path)
	if err != nil {
		log.Fatal(err)
	}
	defer f.Close()
	r := bufio.NewReaderSize(f, 16<<20)
	index := 0
	done := false
	for !done {
		if maxSamples > 0 && st.samplesRead.Load() >= maxSamples {
			return
		}
		if pastDeadline(deadline) {
			st.stoppedEarly.Store(true)
			return
		}
		buf := make([]byte, 0, targetSamples*64)
		var samples, lines int64
		for samples < targetSamples && (maxSamples == 0 || st.samplesRead.Load()+samples < maxSamples) {
			line, err := r.ReadBytes('\n')
			if len(line) > 0 {
				if line[len(line)-1] != '\n' {
					line = append(line, '\n')
				}
				buf = append(buf, line...)
				samples += fieldCount(line)
				lines++
			}
			if err != nil {
				if errors.Is(err, io.EOF) {
					done = true
					break
				}
				log.Fatal(err)
			}
		}
		if lines == 0 {
			return
		}
		st.linesRead.Add(lines)
		st.samplesRead.Add(samples)
		jobs <- batch{index: index, raw: buf, samples: samples}
		index++
	}
}

func post(client *http.Client, url string, body []byte, auth string) (int, float64, time.Duration, string, error) {
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return 0, 0, 0, "", err
	}
	req.Header.Set("content-type", "application/x-protobuf")
	req.Header.Set("content-encoding", "snappy")
	req.Header.Set("x-prometheus-remote-write-version", "0.1.0")
	if auth != "" {
		req.Header.Set("authorization", auth)
	}
	started := time.Now()
	res, err := client.Do(req)
	if err != nil {
		return 0, 0, 0, "", err
	}
	defer res.Body.Close()
	text, _ := io.ReadAll(io.LimitReader(res.Body, 4096))
	_, _ = io.Copy(io.Discard, res.Body)
	elapsed := float64(time.Since(started).Microseconds()) / 1000
	wait := time.Second
	if v, err := strconv.ParseFloat(res.Header.Get("Retry-After"), 64); err == nil {
		wait = min(time.Duration(v*float64(time.Second)), maxRetryAfter)
	}
	return res.StatusCode, elapsed, wait, string(text), nil
}

func permanent(status int) bool {
	switch status {
	case http.StatusBadRequest, http.StatusUnauthorized, http.StatusRequestEntityTooLarge, http.StatusUnsupportedMediaType, http.StatusConflict:
		return true
	}
	return false
}

func work(client *http.Client, urls []string, auth string, deadline time.Time, jobs <-chan batch, st *stats) {
	for b := range jobs {
		proto, samples, err := encode(b.raw, st)
		if err != nil {
			log.Fatalf("batch %d: %v", b.index, err)
		}
		st.bytesDecoded.Add(int64(len(proto)))
		body := snappy.Encode(nil, proto)
		url := urls[b.index%len(urls)]
		backoff := time.Second
		done := false
		for attempt := 1; !done; attempt++ {
			status, ms, wait, text, err := post(client, url, body, auth)
			st.requests.Add(1)
			st.bytesSent.Add(int64(len(body)))
			if err != nil {
				st.recordStatus(0)
			} else {
				st.recordStatus(status)
			}
			switch {
			case err == nil && status/100 == 2:
				st.recordLatency(ms)
				st.samplesAccepted.Add(samples)
				st.lastDoneAt.Store(time.Now().UnixNano())
				done = true
			case err == nil && permanent(status):
				log.Printf("batch %d refused with %d, %d samples rejected: %s", b.index, status, samples, strings.TrimSpace(text))
				st.samplesRejected.Add(samples)
				done = true
			case err == nil && (status == http.StatusTooManyRequests || status == http.StatusServiceUnavailable):
				st.retriesBusy.Add(1)
				if pastDeadline(deadline) {
					st.stoppedEarly.Store(true)
					st.samplesFailed.Add(samples)
					done = true
					continue
				}
				time.Sleep(wait)
			default:
				st.retriesOther.Add(1)
				if attempt == 1 || attempt%5 == 0 {
					log.Printf("batch %d attempt %d: status %d err %v %s", b.index, attempt, status, err, strings.TrimSpace(text))
				}
				if attempt >= maxAttempts || pastDeadline(deadline) {
					log.Printf("batch %d gave up after %d attempts, %d samples lost", b.index, attempt, samples)
					st.stoppedEarly.Store(pastDeadline(deadline))
					st.samplesFailed.Add(samples)
					done = true
					continue
				}
				time.Sleep(backoff)
				backoff = min(backoff*2, 8*time.Second)
			}
		}
	}
}

type point struct {
	at      time.Time
	samples int64
}

func percentile(sorted []float64, p float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	rank := p / 100 * float64(len(sorted)-1)
	lo := int(rank)
	hi := min(lo+1, len(sorted)-1)
	return sorted[lo] + (sorted[hi]-sorted[lo])*(rank-float64(lo))
}

func snapshot(st *stats, start time.Time, recent []point, final bool, cfg map[string]any) map[string]any {
	st.mu.Lock()
	statuses := map[string]int64{}
	for code, n := range st.statuses {
		statuses[strconv.Itoa(code)] = n
	}
	latencies := append([]float64(nil), st.latenciesMs...)
	st.mu.Unlock()

	elapsed := time.Since(start).Seconds()
	if final && st.lastDoneAt.Load() > 0 {
		elapsed = time.Unix(0, st.lastDoneAt.Load()).Sub(start).Seconds()
	}
	accepted := st.samplesAccepted.Load()
	cpu := clientCPUSeconds()
	out := map[string]any{
		"lines_read":          st.linesRead.Load(),
		"samples_read":        st.samplesRead.Load(),
		"samples_accepted":    accepted,
		"samples_rejected":    st.samplesRejected.Load(),
		"samples_failed":      st.samplesFailed.Load(),
		"requests":            st.requests.Load(),
		"retries_busy":        st.retriesBusy.Load(),
		"retries_other":       st.retriesOther.Load(),
		"responses":           statuses,
		"duration_s":          elapsed,
		"samples_per_s":       float64(accepted) / max(elapsed, 1e-9),
		"data_sent_mib":       float64(st.bytesSent.Load()) / 1048576,
		"data_decoded_mib":    float64(st.bytesDecoded.Load()) / 1048576,
		"samples_per_request": float64(accepted) / float64(max(len(latencies), 1)),
		"first_ts_ms":         st.minTsMs.Load(),
		"last_ts_ms":          st.maxTsMs.Load(),
		"stopped_early":       st.stoppedEarly.Load(),
		"client_cpu_s":        cpu,
		"client_cores":        cpu / max(elapsed, 1e-9),
	}
	for k, v := range cfg {
		out[k] = v
	}
	if n := len(recent); n >= 2 {
		span := recent[n-1].at.Sub(recent[0].at).Seconds()
		out["samples_per_s_recent"] = float64(recent[n-1].samples-recent[0].samples) / max(span, 1e-9)
	}
	sort.Float64s(latencies)
	sum := 0.0
	for _, v := range latencies {
		sum += v
	}
	out["latency_ms"] = map[string]any{
		"min": percentile(latencies, 0),
		"med": percentile(latencies, 50),
		"p90": percentile(latencies, 90),
		"p99": percentile(latencies, 99),
		"max": percentile(latencies, 100),
		"avg": sum / float64(max(len(latencies), 1)),
	}
	return out
}

func writeJSON(path string, value any) {
	if path == "" {
		return
	}
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		log.Fatal(err)
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0o644); err != nil {
		log.Fatal(err)
	}
	if err := os.Rename(tmp, path); err != nil {
		log.Fatal(err)
	}
}

func main() {
	file := flag.String("file", "", "the TSBS data file, -format=victoriametrics (required)")
	urlList := flag.String("urls", "", "comma-separated remote write URLs (required)")
	samples := flag.Int64("samples", 10_000, "target samples per request, as vmagent sends them")
	workers := flag.Int("workers", 8, "concurrent requests")
	maxSamples := flag.Int64("max-samples", 0, "stop after this many samples (0 = whole file)")
	timeout := flag.Duration("timeout", 60*time.Second, "per-request timeout")
	progress := flag.String("progress", "", "progress JSON path, rewritten every 5s")
	out := flag.String("out", "", "summary JSON path")
	deadline := flag.Duration("deadline", 0, "stop cutting batches and stop retrying after this long (0 = never)")
	flag.Parse()

	urls := strings.Split(*urlList, ",")
	for i := range urls {
		urls[i] = strings.TrimSpace(urls[i])
	}
	if *file == "" || *urlList == "" {
		log.Fatal("-file and -urls are required")
	}
	for _, path := range []string{*progress, *out} {
		if path != "" {
			if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
				log.Fatal(err)
			}
		}
	}

	auth := os.Getenv("AUTH")
	client := &http.Client{
		Timeout: *timeout,
		Transport: &http.Transport{
			MaxIdleConns:        *workers * 2,
			MaxIdleConnsPerHost: *workers * 2,
			DisableCompression:  true,
			IdleConnTimeout:     90 * time.Second,
		},
	}

	st := &stats{statuses: map[int]int64{}}
	cfg := map[string]any{
		"file":    *file,
		"urls":    len(urls),
		"workers": *workers,
		"samples": *samples,
	}
	var stopAt time.Time
	if *deadline > 0 {
		stopAt = time.Now().Add(*deadline)
	}

	start := time.Now()
	jobs := make(chan batch, *workers*2)
	go readBatches(*file, *samples, *maxSamples, stopAt, jobs, st)

	var wg sync.WaitGroup
	for range *workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			work(client, urls, auth, stopAt, jobs, st)
		}()
	}

	finished := make(chan struct{})
	go func() {
		wg.Wait()
		close(finished)
	}()

	ticker := time.NewTicker(progressEvery)
	defer ticker.Stop()
	var recent []point
	for running := true; running; {
		select {
		case <-finished:
			running = false
		case now := <-ticker.C:
			recent = append(recent, point{at: now, samples: st.samplesAccepted.Load()})
			if len(recent) > 6 {
				recent = recent[1:]
			}
			snap := snapshot(st, start, recent, false, cfg)
			writeJSON(*progress, snap)
			log.Printf("%d samples accepted, %.0f/s recent, %d busy retries",
				st.samplesAccepted.Load(), snap["samples_per_s_recent"], st.retriesBusy.Load())
		}
	}

	summary := snapshot(st, start, recent, true, cfg)
	writeJSON(*progress, summary)
	writeJSON(*out, summary)
	data, _ := json.MarshalIndent(summary, "", "  ")
	fmt.Println(string(data))
	if st.samplesRejected.Load() > 0 || st.samplesFailed.Load() > 0 {
		os.Exit(1)
	}
}
