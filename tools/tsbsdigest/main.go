// tsbsdigest reduces the answers that `tsbs_run_queries_* --print-responses`
// prints to one line each, so two builds' answers compare without moving
// megabytes of JSON. It reads the runner's output on stdin, groups the
// `ID <n>: ` lines by query, and prints `ID <n> status=<s> series=<k>
// points=<p> sha256=<hex>` per answer. The hash covers the answer's
// `resultType` and every series, its labels sorted and its values formatted
// to -digits significant digits, the series sorted by their labels. Timings
// and `stats` are left out. An error answer prints its message instead of a
// hash.
package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

type answer struct {
	Status string `json:"status"`
	Error  string `json:"error"`
	Data   struct {
		ResultType string            `json:"resultType"`
		Result     []json.RawMessage `json:"result"`
	} `json:"data"`
}

type series struct {
	Metric map[string]string `json:"metric"`
	Values [][2]any          `json:"values"`
	Value  [2]any            `json:"value"`
}

var idLine = regexp.MustCompile(`^ID (\d+): ?(.*)$`)

func canonicalValue(v any, digits int) string {
	s, ok := v.(string)
	if !ok {
		return fmt.Sprint(v)
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return s
	}
	return strconv.FormatFloat(f, 'g', digits, 64)
}

func canonicalTime(v any) string {
	switch t := v.(type) {
	case float64:
		return strconv.FormatFloat(t, 'f', -1, 64)
	default:
		return fmt.Sprint(t)
	}
}

func digest(body string, digits int) string {
	var a answer
	if err := json.Unmarshal([]byte(body), &a); err != nil {
		return fmt.Sprintf("status=unparsed error=%q", err.Error())
	}
	if a.Status != "success" {
		return fmt.Sprintf("status=%s error=%q", a.Status, a.Error)
	}
	lines := make([]string, 0, len(a.Data.Result))
	points := 0
	for _, raw := range a.Data.Result {
		var s series
		if err := json.Unmarshal(raw, &s); err != nil {
			return fmt.Sprintf("status=unparsed error=%q", err.Error())
		}
		keys := make([]string, 0, len(s.Metric))
		for k := range s.Metric {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		var b strings.Builder
		for _, k := range keys {
			fmt.Fprintf(&b, "%s=%q,", k, s.Metric[k])
		}
		b.WriteString("|")
		values := s.Values
		if values == nil && s.Value[0] != nil {
			values = [][2]any{s.Value}
		}
		for _, v := range values {
			fmt.Fprintf(&b, "%s:%s;", canonicalTime(v[0]), canonicalValue(v[1], digits))
		}
		points += len(values)
		lines = append(lines, b.String())
	}
	sort.Strings(lines)
	h := sha256.New()
	h.Write([]byte(a.Data.ResultType + "\n"))
	for _, l := range lines {
		h.Write([]byte(l + "\n"))
	}
	return fmt.Sprintf("status=success series=%d points=%d sha256=%x", len(lines), points, h.Sum(nil))
}

func main() {
	digits := flag.Int("digits", 10, "significant digits a value is compared to")
	flag.Parse()

	bodies := map[int]*strings.Builder{}
	var order []int
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 1<<20), 1<<30)
	for scanner.Scan() {
		m := idLine.FindStringSubmatch(scanner.Text())
		if m == nil {
			continue
		}
		id, _ := strconv.Atoi(m[1])
		b, ok := bodies[id]
		if !ok {
			b = &strings.Builder{}
			bodies[id] = b
			order = append(order, id)
		}
		b.WriteString(m[2])
		b.WriteByte('\n')
	}
	if err := scanner.Err(); err != nil {
		log.Fatal(err)
	}
	sort.Ints(order)
	for _, id := range order {
		fmt.Printf("ID %d %s\n", id, digest(bodies[id].String(), *digits))
	}
}
