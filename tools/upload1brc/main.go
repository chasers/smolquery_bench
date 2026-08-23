// upload1brc streams a `station;temperature` measurements file into a
// smolquery table as NDJSON inserts: the file is cut into batches of about
// -rows lines, each batch is converted to one JSON object per line and posted
// by one of -workers goroutines, round-robin across -urls. Every batch carries
// an insertId, so a retry after a 429, a 5xx, a timeout or a dropped
// connection cannot double-count rows. The authorization header value comes
// from the AUTH environment variable, never from the command line.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	bytesPerRow   = 14
	maxAttempts   = 30
	progressEvery = 5 * time.Second
)

type batch struct {
	index int
	raw   []byte
}

type stats struct {
	mu           sync.Mutex
	latenciesMs  []float64
	rowsRead     atomic.Int64
	rowsAccepted atomic.Int64
	rowsRejected atomic.Int64
	rowsFailed   atomic.Int64
	bytesSent    atomic.Int64
	requests     atomic.Int64
	retries429   atomic.Int64
	retriesOther atomic.Int64
	statuses     map[int]int64
	firstSentAt  atomic.Int64
	lastDoneAt   atomic.Int64
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

type insertResponse struct {
	InsertedRows int64 `json:"insertedRows"`
	ErrorCount   int64 `json:"errorCount"`
}

func convert(raw []byte) ([]byte, int64) {
	out := make([]byte, 0, len(raw)*3)
	var rows int64
	for len(raw) > 0 {
		nl := bytes.IndexByte(raw, '\n')
		var line []byte
		if nl < 0 {
			line, raw = raw, nil
		} else {
			line, raw = raw[:nl], raw[nl+1:]
		}
		if len(line) == 0 {
			continue
		}
		sep := bytes.IndexByte(line, ';')
		if sep < 0 {
			continue
		}
		out = append(out, `{"station":`...)
		if bytes.IndexAny(line[:sep], "\"\\") < 0 {
			out = append(out, '"')
			out = append(out, line[:sep]...)
			out = append(out, '"')
		} else {
			out = strconv.AppendQuote(out, string(line[:sep]))
		}
		out = append(out, `,"temperature":`...)
		out = append(out, line[sep+1:]...)
		out = append(out, "}\n"...)
		rows++
	}
	return out, rows
}

func readBatches(path string, targetBytes int, maxRows int64, jobs chan<- batch, st *stats) {
	defer close(jobs)
	f, err := os.Open(path)
	if err != nil {
		log.Fatal(err)
	}
	defer f.Close()
	r := bufio.NewReaderSize(f, 16<<20)
	index := 0
	for {
		if maxRows > 0 && st.rowsRead.Load() >= maxRows {
			return
		}
		buf := make([]byte, 0, targetBytes+256)
		var rows int64
		for len(buf) < targetBytes && (maxRows == 0 || st.rowsRead.Load()+rows < maxRows) {
			line, err := r.ReadSlice('\n')
			buf = append(buf, line...)
			if len(line) > 0 && line[len(line)-1] == '\n' {
				rows++
			} else if len(line) > 0 {
				rows++
				buf = append(buf, '\n')
			}
			if err != nil {
				if errors.Is(err, io.EOF) {
					break
				}
				if errors.Is(err, bufio.ErrBufferFull) {
					continue
				}
				log.Fatal(err)
			}
		}
		if len(buf) == 0 {
			return
		}
		st.rowsRead.Add(rows)
		jobs <- batch{index: index, raw: buf}
		index++
		if rows == 0 {
			return
		}
	}
}

func post(client *http.Client, url string, body []byte, auth string) (int, insertResponse, float64, error) {
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return 0, insertResponse{}, 0, err
	}
	req.Header.Set("content-type", "application/x-ndjson")
	if auth != "" {
		req.Header.Set("authorization", auth)
	}
	started := time.Now()
	res, err := client.Do(req)
	if err != nil {
		return 0, insertResponse{}, 0, err
	}
	defer res.Body.Close()
	var parsed insertResponse
	if res.StatusCode == http.StatusOK {
		if err := json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&parsed); err != nil {
			return res.StatusCode, parsed, 0, fmt.Errorf("decode response: %w", err)
		}
	}
	_, _ = io.Copy(io.Discard, res.Body)
	elapsed := float64(time.Since(started).Microseconds()) / 1000
	if res.StatusCode == http.StatusTooManyRequests {
		wait := 1.0
		if v, err := strconv.ParseFloat(res.Header.Get("Retry-After"), 64); err == nil {
			wait = v
		}
		return res.StatusCode, parsed, min(wait, 2), nil
	}
	return res.StatusCode, parsed, elapsed, nil
}

func work(client *http.Client, urls []string, auth, prefix string, jobs <-chan batch, st *stats) {
	for b := range jobs {
		body, rows := convert(b.raw)
		url := fmt.Sprintf("%s?insertId=%s-%d", urls[b.index%len(urls)], prefix, b.index)
		backoff := time.Second
		done := false
		for attempt := 1; attempt <= maxAttempts && !done; attempt++ {
			st.firstSentAt.CompareAndSwap(0, time.Now().UnixNano())
			status, parsed, value, err := post(client, url, body, auth)
			st.requests.Add(1)
			st.bytesSent.Add(int64(len(body)))
			switch {
			case err == nil && status == http.StatusOK:
				st.recordStatus(status)
				st.recordLatency(value)
				st.rowsAccepted.Add(parsed.InsertedRows)
				st.rowsRejected.Add(rows - parsed.InsertedRows)
				st.lastDoneAt.Store(time.Now().UnixNano())
				done = true
			case err == nil && status == http.StatusTooManyRequests:
				st.recordStatus(status)
				st.retries429.Add(1)
				time.Sleep(time.Duration(value * float64(time.Second)))
			default:
				if err == nil {
					st.recordStatus(status)
				} else {
					st.recordStatus(0)
				}
				st.retriesOther.Add(1)
				if attempt == 1 || attempt%5 == 0 {
					log.Printf("batch %d attempt %d: status %d err %v", b.index, attempt, status, err)
				}
				time.Sleep(backoff)
				backoff = min(backoff*2, 8*time.Second)
			}
		}
		if !done {
			log.Printf("batch %d failed after %d attempts, %d rows lost", b.index, maxAttempts, rows)
			st.rowsFailed.Add(rows)
		}
	}
}

type sample struct {
	at   time.Time
	rows int64
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

func snapshot(st *stats, start time.Time, recent []sample, final bool, cfg map[string]any) map[string]any {
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
	accepted := st.rowsAccepted.Load()
	out := map[string]any{
		"rows_read":        st.rowsRead.Load(),
		"rows_accepted":    accepted,
		"rows_rejected":    st.rowsRejected.Load(),
		"rows_failed":      st.rowsFailed.Load(),
		"requests":         st.requests.Load(),
		"retries_429":      st.retries429.Load(),
		"retries_other":    st.retriesOther.Load(),
		"responses":        statuses,
		"duration_s":       elapsed,
		"rows_per_s":       float64(accepted) / max(elapsed, 1e-9),
		"data_sent_mib":    float64(st.bytesSent.Load()) / 1048576,
		"mib_per_s":        float64(st.bytesSent.Load()) / 1048576 / max(elapsed, 1e-9),
		"rows_per_request": float64(accepted) / float64(max(len(latencies), 1)),
	}
	for k, v := range cfg {
		out[k] = v
	}
	if n := len(recent); n >= 2 {
		span := recent[n-1].at.Sub(recent[0].at).Seconds()
		out["rows_per_s_recent"] = float64(recent[n-1].rows-recent[0].rows) / max(span, 1e-9)
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
		"p95": percentile(latencies, 95),
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
	file := flag.String("file", "measurements.txt", "the station;temperature file")
	urlList := flag.String("urls", "", "comma-separated insert URLs (required)")
	rows := flag.Int("rows", 200_000, "target rows per request")
	workers := flag.Int("workers", 8, "concurrent requests")
	maxRows := flag.Int64("max-rows", 0, "stop after this many rows (0 = whole file)")
	timeout := flag.Duration("timeout", 120*time.Second, "per-request timeout")
	progress := flag.String("progress", "", "progress JSON path, rewritten every 5s")
	out := flag.String("out", "", "summary JSON path")
	prefix := flag.String("insert-prefix", "", "insertId prefix (default: onebrc-<unix seconds>)")
	flag.Parse()

	urls := strings.Split(*urlList, ",")
	for i := range urls {
		urls[i] = strings.TrimSpace(urls[i])
	}
	if *urlList == "" || len(urls) == 0 {
		log.Fatal("-urls is required")
	}
	if *prefix == "" {
		*prefix = fmt.Sprintf("onebrc-%d", time.Now().Unix())
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
		"file":                    *file,
		"urls":                    urls,
		"targets":                 len(urls),
		"workers":                 *workers,
		"rows_per_request_target": *rows,
		"insert_prefix":           *prefix,
	}

	jobs := make(chan batch, *workers*2)
	start := time.Now()
	go readBatches(*file, *rows*bytesPerRow, *maxRows, jobs, st)

	var wg sync.WaitGroup
	for i := 0; i < *workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			work(client, urls, auth, *prefix, jobs, st)
		}()
	}
	finished := make(chan struct{})
	go func() {
		wg.Wait()
		close(finished)
	}()

	ticker := time.NewTicker(progressEvery)
	defer ticker.Stop()
	var recent []sample
	for running := true; running; {
		select {
		case <-finished:
			running = false
		case now := <-ticker.C:
			recent = append(recent, sample{at: now, rows: st.rowsAccepted.Load()})
			if len(recent) > 3 {
				recent = recent[len(recent)-3:]
			}
			snap := snapshot(st, start, recent, false, cfg)
			writeJSON(*progress, snap)
			fmt.Fprintf(os.Stderr, "%d rows accepted, %.0f rows/s overall, %.0f rows/s recent, %d requests, %d x 429\n",
				snap["rows_accepted"], snap["rows_per_s"], snap["rows_per_s_recent"], snap["requests"], snap["retries_429"])
		}
	}

	summary := snapshot(st, start, nil, true, cfg)
	summary["inserted_at"] = time.Now().UTC().Format("2006-01-02T15:04:05Z")
	writeJSON(*progress, summary)
	writeJSON(*out, summary)
	fmt.Printf("%d rows accepted in %.1fs: %.0f rows/s, %.1f MiB/s, %d requests, %d rejected, %d failed, %d x 429, %d other retries\n",
		summary["rows_accepted"], summary["duration_s"], summary["rows_per_s"], summary["mib_per_s"],
		summary["requests"], summary["rows_rejected"], summary["rows_failed"], summary["retries_429"], summary["retries_other"])
}
