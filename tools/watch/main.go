package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type matchList []string

func (m *matchList) String() string { return strings.Join(*m, ",") }

func (m *matchList) Set(v string) error {
	*m = append(*m, v)
	return nil
}

type series struct {
	pattern string
	re      *regexp.Regexp
	cpu     []float64
	rssKB   []int64
}

type report struct {
	Pattern    string  `json:"pattern"`
	Samples    int     `json:"samples"`
	CPUAvgPct  float64 `json:"cpu_avg_pct"`
	CPUPeakPct float64 `json:"cpu_peak_pct"`
	RSSMeanMB  float64 `json:"rss_mean_mb"`
	RSSPeakMB  float64 `json:"rss_peak_mb"`
}

func sample(all []*series, self int) error {
	out, err := exec.Command("ps", "-axo", "pid=,pcpu=,rss=,args=").Output()
	if err != nil {
		return err
	}

	cpu := make([]float64, len(all))
	rss := make([]int64, len(all))

	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}
		pid, _ := strconv.Atoi(fields[0])
		if pid == self {
			continue
		}
		args := strings.Join(fields[3:], " ")
		if strings.HasPrefix(args, "ps -axo") {
			continue
		}
		for i, s := range all {
			if s.re.MatchString(args) {
				pcpu, _ := strconv.ParseFloat(fields[1], 64)
				kb, _ := strconv.ParseInt(fields[2], 10, 64)
				cpu[i] += pcpu
				rss[i] += kb
			}
		}
	}

	for i, s := range all {
		s.cpu = append(s.cpu, cpu[i])
		s.rssKB = append(s.rssKB, rss[i])
	}
	return nil
}

func summarize(all []*series) []report {
	reports := make([]report, 0, len(all))
	for _, s := range all {
		r := report{Pattern: s.pattern, Samples: len(s.cpu)}
		var cpuSum, rssSum float64
		for i := range s.cpu {
			cpuSum += s.cpu[i]
			rssSum += float64(s.rssKB[i])
			if s.cpu[i] > r.CPUPeakPct {
				r.CPUPeakPct = s.cpu[i]
			}
			if mb := float64(s.rssKB[i]) / 1024; mb > r.RSSPeakMB {
				r.RSSPeakMB = mb
			}
		}
		if n := float64(len(s.cpu)); n > 0 {
			r.CPUAvgPct = cpuSum / n
			r.RSSMeanMB = rssSum / n / 1024
		}
		reports = append(reports, r)
	}
	return reports
}

func main() {
	var matches matchList
	flag.Var(&matches, "match", "regexp over process args, repeatable")
	interval := flag.Duration("interval", time.Second, "sampling interval")
	duration := flag.Duration("duration", 60*time.Second, "how long to sample")
	out := flag.String("out", "", "output JSON path (default stdout)")
	flag.Parse()

	if len(matches) == 0 {
		log.Fatal("at least one -match is required")
	}

	all := make([]*series, 0, len(matches))
	for _, p := range matches {
		all = append(all, &series{pattern: p, re: regexp.MustCompile(p)})
	}

	self := os.Getpid()
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	deadline := time.After(*duration)
	tick := time.NewTicker(*interval)
	defer tick.Stop()

sampling:
	for {
		select {
		case <-tick.C:
			if err := sample(all, self); err != nil {
				log.Fatal(err)
			}
		case <-deadline:
			break sampling
		case <-stop:
			break sampling
		}
	}

	payload := map[string]any{
		"inserted_at": time.Now().UTC().Format(time.RFC3339),
		"interval_s":  interval.Seconds(),
		"processes":   summarize(all),
	}
	blob, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		log.Fatal(err)
	}

	if *out == "" {
		fmt.Println(string(blob))
		return
	}
	if err := os.MkdirAll(filepath.Dir(*out), 0o755); err != nil {
		log.Fatal(err)
	}
	if err := os.WriteFile(*out, append(blob, '\n'), 0o644); err != nil {
		log.Fatal(err)
	}
}
