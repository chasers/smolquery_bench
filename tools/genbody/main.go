package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type row struct {
	ProjectID              string  `json:"project_id"`
	Timestamp              string  `json:"timestamp"`
	ObservedTimestamp      string  `json:"observed_timestamp"`
	SeverityNumber         int     `json:"severity_number"`
	SeverityText           string  `json:"severity_text"`
	Body                   string  `json:"body"`
	TraceID                string  `json:"trace_id"`
	SpanID                 string  `json:"span_id"`
	TraceFlags             int     `json:"trace_flags"`
	DroppedAttributesCount int     `json:"dropped_attributes_count"`
	ServiceName            string  `json:"service_name"`
	ServiceNamespace       string  `json:"service_namespace"`
	ServiceVersion         string  `json:"service_version"`
	ServiceInstanceID      string  `json:"service_instance_id"`
	DeploymentEnvironment  string  `json:"deployment_environment"`
	CloudProvider          string  `json:"cloud_provider"`
	CloudRegion            string  `json:"cloud_region"`
	CloudAvailabilityZone  string  `json:"cloud_availability_zone"`
	CloudAccountID         string  `json:"cloud_account_id"`
	K8sClusterName         string  `json:"k8s_cluster_name"`
	K8sNamespaceName       string  `json:"k8s_namespace_name"`
	K8sDeploymentName      string  `json:"k8s_deployment_name"`
	K8sPodName             string  `json:"k8s_pod_name"`
	K8sPodUID              string  `json:"k8s_pod_uid"`
	K8sContainerName       string  `json:"k8s_container_name"`
	K8sNodeName            string  `json:"k8s_node_name"`
	HostName               string  `json:"host_name"`
	HostArch               string  `json:"host_arch"`
	OsType                 string  `json:"os_type"`
	OsVersion              string  `json:"os_version"`
	ContainerID            string  `json:"container_id"`
	ContainerImageTag      string  `json:"container_image_tag"`
	TelemetrySdkName       string  `json:"telemetry_sdk_name"`
	TelemetrySdkLanguage   string  `json:"telemetry_sdk_language"`
	TelemetrySdkVersion    string  `json:"telemetry_sdk_version"`
	ScopeName              string  `json:"scope_name"`
	ScopeVersion           string  `json:"scope_version"`
	CodeNamespace          string  `json:"code_namespace"`
	CodeFunction           string  `json:"code_function"`
	CodeLineno             int     `json:"code_lineno"`
	HTTPRequestMethod      string  `json:"http_request_method"`
	HTTPRoute              string  `json:"http_route"`
	HTTPResponseStatusCode int     `json:"http_response_status_code"`
	HTTPRequestBodySize    int     `json:"http_request_body_size"`
	HTTPResponseBodySize   int     `json:"http_response_body_size"`
	URLPath                string  `json:"url_path"`
	URLScheme              string  `json:"url_scheme"`
	NetworkProtocolVersion string  `json:"network_protocol_version"`
	UserAgentOriginal      string  `json:"user_agent_original"`
	ClientAddress          string  `json:"client_address"`
	ServerAddress          string  `json:"server_address"`
	ServerPort             int     `json:"server_port"`
	DurationMs             float64 `json:"duration_ms"`
	ErrorType              *string `json:"error_type"`
	ExceptionType          *string `json:"exception_type"`
	ExceptionMessage       *string `json:"exception_message"`
	ExceptionStacktrace    *string `json:"exception_stacktrace"`
	EnduserID              string  `json:"enduser_id"`
	SessionID              string  `json:"session_id"`
	ThreadName             string  `json:"thread_name"`
	LogFilePath            string  `json:"log_file_path"`
	Sampled                bool    `json:"sampled"`
	InsertedAt             string  `json:"inserted_at"`
}

// insertedAtPlaceholder is substituted with the send time by whatever posts
// the body — k6/insert.js per request, and the preflight in scripts/bench.exs.
// It is exactly 26 characters, matching the zone-less microsecond format the
// other timestamp columns use — both default parsers reject a trailing Z.
const insertedAtPlaceholder = "____INSERTED_AT___________"

type kvRow struct {
	Key        string `json:"key"`
	Timestamp  string `json:"timestamp"`
	Value      string `json:"value"`
	InsertedAt string `json:"inserted_at"`
}

var kvNames = []string{"cart.items", "cache.hits", "queue.depth", "session.count", "request.bytes"}

func generateKV(r *rand.Rand, base time.Time, i, projects int) kvRow {
	return kvRow{
		Key:        fmt.Sprintf("proj_%04d:%s", r.Intn(projects), pick(r, kvNames)),
		Timestamp:  iso(base.Add(time.Duration(i) * 317 * time.Microsecond)),
		Value:      fmt.Sprintf("%d", r.Intn(1_000_000)),
		InsertedAt: insertedAtPlaceholder,
	}
}

var (
	services  = []string{"checkout-api", "cart-api", "catalog-api", "payments-api", "auth-api"}
	routes    = []string{"/v1/checkout", "/v1/cart", "/v1/cart/:id", "/v1/catalog/items", "/v1/auth/token"}
	methods   = []string{"GET", "POST", "PUT", "DELETE"}
	regions   = []string{"us-east-1", "us-west-2", "eu-central-1"}
	languages = []string{"go", "python", "nodejs", "java", "erlang"}
	functions = []string{"handle_request", "process_order", "fetch_items", "issue_token", "update_cart"}
	agents    = []string{
		"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
		"Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
		"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36 Edg/125.0.0.0",
		"curl/8.6.0",
		"okhttp/4.12.0",
	}
	bodies = []string{
		"handled %s %s in %.1f ms",
		"request completed: %s %s status=%d bytes=%d",
		"cache miss for key session:%s, fetched from origin in %.1f ms",
		"upstream call to %s finished with status %d after %.1f ms",
		"slow query detected on %s: %.1f ms over threshold, returning partial result set to caller",
	}
	filler = " retrying with backoff and jitter while the connection pool drains outstanding checkouts before the deadline expires"
)

func hexs(r *rand.Rand, n int) string {
	const digits = "0123456789abcdef"
	b := make([]byte, n)
	for i := range b {
		b[i] = digits[r.Intn(16)]
	}
	return string(b)
}

func pick(r *rand.Rand, list []string) string {
	return list[r.Intn(len(list))]
}

func uuid(r *rand.Rand) string {
	return fmt.Sprintf("%s-%s-%s-%s-%s", hexs(r, 8), hexs(r, 4), hexs(r, 4), hexs(r, 4), hexs(r, 12))
}

func iso(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05.000000")
}

// resolveBase returns the first timestamp of the generated rows. An empty
// date means today at 10:00 UTC, so a body carries the date of the run that
// generates it. An explicit YYYY-MM-DD backdates the body, which is how a
// partitioned table gets rows in more than one date partition.
func resolveBase(date string) (time.Time, error) {
	if date == "" {
		now := time.Now().UTC()
		return time.Date(now.Year(), now.Month(), now.Day(), 10, 0, 0, 0, time.UTC), nil
	}

	day, err := time.Parse("2006-01-02", date)
	if err != nil {
		return time.Time{}, fmt.Errorf("base-date %q is not YYYY-MM-DD: %w", date, err)
	}

	return time.Date(day.Year(), day.Month(), day.Day(), 10, 0, 0, 0, time.UTC), nil
}

func generate(r *rand.Rand, base time.Time, i, projects int) row {
	ts := base.Add(time.Duration(i) * 317 * time.Microsecond)
	service := pick(r, services)
	routeIdx := r.Intn(len(routes))
	route := routes[routeIdx]
	method := pick(r, methods)
	version := fmt.Sprintf("1.%d.%d", r.Intn(9), r.Intn(20))
	region := pick(r, regions)
	node := fmt.Sprintf("ip-10-0-%d-%d.ec2.internal", r.Intn(64), r.Intn(256))

	severityNumber, severityText := 9, "INFO"
	switch roll := r.Float64(); {
	case roll < 0.03:
		severityNumber, severityText = 17, "ERROR"
	case roll < 0.08:
		severityNumber, severityText = 13, "WARN"
	case roll < 0.11:
		severityNumber, severityText = 5, "DEBUG"
	}
	isError := severityNumber == 17

	status := 200
	switch {
	case isError:
		status = []int{500, 502, 503}[r.Intn(3)]
	case r.Float64() < 0.05:
		status = []int{400, 404, 422}[r.Intn(3)]
	case method == "POST":
		status = 201
	}

	durationMs := math.Round(math.Exp(r.NormFloat64()*0.9+3.0)*10) / 10

	body := fmt.Sprintf(pick(r, bodies), method, route, durationMs, status)
	for n := r.Intn(4); n > 0; n-- {
		body += filler
	}

	requestBodySize := 0
	if method == "POST" || method == "PUT" {
		requestBodySize = 64 + r.Intn(4096)
	}

	urlPath := strings.Replace(route, ":id", fmt.Sprintf("%d", r.Intn(100000)), 1)

	var errorType, exceptionType, exceptionMessage, exceptionStacktrace *string
	if isError {
		et := "HTTPError"
		xt := pick(r, []string{"TimeoutError", "ConnectionResetError", "UpstreamUnavailable"})
		xm := fmt.Sprintf("%s: upstream %s did not answer within %.0f ms", xt, service, durationMs)
		frames := make([]string, 0, 14)
		frames = append(frames, xm)
		for f := 0; f < 12; f++ {
			frames = append(frames, fmt.Sprintf("  at %s.%s(%s.%s:%d)",
				"app.handlers", pick(r, functions), service, "go", 20+r.Intn(400)))
		}
		xs := strings.Join(frames, "\n")
		errorType, exceptionType, exceptionMessage, exceptionStacktrace = &et, &xt, &xm, &xs
	}

	return row{
		ProjectID:              fmt.Sprintf("proj_%04d", r.Intn(projects)),
		Timestamp:              iso(ts),
		ObservedTimestamp:      iso(ts.Add(time.Duration(1+r.Intn(40)) * time.Millisecond)),
		SeverityNumber:         severityNumber,
		SeverityText:           severityText,
		Body:                   body,
		TraceID:                hexs(r, 32),
		SpanID:                 hexs(r, 16),
		TraceFlags:             1,
		DroppedAttributesCount: 0,
		ServiceName:            service,
		ServiceNamespace:       "shop",
		ServiceVersion:         version,
		ServiceInstanceID:      uuid(r),
		DeploymentEnvironment:  "production",
		CloudProvider:          "aws",
		CloudRegion:            region,
		CloudAvailabilityZone:  region + pick(r, []string{"a", "b", "c"}),
		CloudAccountID:         "123456789012",
		K8sClusterName:         "prod-eks-1",
		K8sNamespaceName:       service,
		K8sDeploymentName:      service,
		K8sPodName:             fmt.Sprintf("%s-%s-%s", service, hexs(r, 9), hexs(r, 5)),
		K8sPodUID:              uuid(r),
		K8sContainerName:       service,
		K8sNodeName:            node,
		HostName:               node,
		HostArch:               pick(r, []string{"amd64", "arm64"}),
		OsType:                 "linux",
		OsVersion:              "6.1.0",
		ContainerID:            hexs(r, 64),
		ContainerImageTag:      version,
		TelemetrySdkName:       "opentelemetry",
		TelemetrySdkLanguage:   pick(r, languages),
		TelemetrySdkVersion:    "1.28.0",
		ScopeName:              service + ".http",
		ScopeVersion:           "1.0.0",
		CodeNamespace:          "app.handlers." + strings.TrimPrefix(strings.SplitN(route[1:]+"/", "/", 3)[1], "/"),
		CodeFunction:           pick(r, functions),
		CodeLineno:             20 + r.Intn(480),
		HTTPRequestMethod:      method,
		HTTPRoute:              route,
		HTTPResponseStatusCode: status,
		HTTPRequestBodySize:    requestBodySize,
		HTTPResponseBodySize:   128 + r.Intn(65536),
		URLPath:                urlPath,
		URLScheme:              "https",
		NetworkProtocolVersion: pick(r, []string{"1.1", "2"}),
		UserAgentOriginal:      pick(r, agents),
		ClientAddress:          fmt.Sprintf("%d.%d.%d.%d", 1+r.Intn(223), r.Intn(256), r.Intn(256), 1+r.Intn(254)),
		ServerAddress:          service + ".shop.internal",
		ServerPort:             8080,
		DurationMs:             durationMs,
		ErrorType:              errorType,
		ExceptionType:          exceptionType,
		ExceptionMessage:       exceptionMessage,
		ExceptionStacktrace:    exceptionStacktrace,
		EnduserID:              fmt.Sprintf("user_%06d", r.Intn(500000)),
		SessionID:              hexs(r, 16),
		ThreadName:             fmt.Sprintf("worker-%d", r.Intn(64)),
		LogFilePath:            "/var/log/app/" + service + ".log",
		Sampled:                r.Float64() < 0.95,
		InsertedAt:             insertedAtPlaceholder,
	}
}

func main() {
	rows := flag.Int("rows", 3062, "rows per body file")
	projects := flag.Int("projects", 1000, "project_id cardinality")
	seed := flag.Int64("seed", 42, "PRNG seed for reproducible bodies")
	out := flag.String("out", "", "output file path (required)")
	baseDate := flag.String("base-date", "", "timestamp date as YYYY-MM-DD (default: today UTC)")
	shape := flag.String("shape", "otel", "row shape: otel (63 columns) or kv (key, timestamp, value)")
	flag.Parse()

	if *out == "" {
		log.Fatal("-out is required")
	}
	if *shape != "otel" && *shape != "kv" {
		log.Fatalf("-shape must be otel or kv, got %q", *shape)
	}
	if err := os.MkdirAll(filepath.Dir(*out), 0o755); err != nil {
		log.Fatal(err)
	}

	f, err := os.Create(*out)
	if err != nil {
		log.Fatal(err)
	}
	defer f.Close()

	w := bufio.NewWriterSize(f, 1<<20)
	enc := json.NewEncoder(w)
	r := rand.New(rand.NewSource(*seed))

	base, err := resolveBase(*baseDate)
	if err != nil {
		log.Fatal(err)
	}

	for i := 0; i < *rows; i++ {
		var encodeErr error
		if *shape == "kv" {
			encodeErr = enc.Encode(generateKV(r, base, i, *projects))
		} else {
			encodeErr = enc.Encode(generate(r, base, i, *projects))
		}
		if encodeErr != nil {
			log.Fatal(encodeErr)
		}
	}
	if err := w.Flush(); err != nil {
		log.Fatal(err)
	}

	info, err := os.Stat(*out)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("%s: %d rows, %.2f MiB (%.0f B/row), seed %d, %d projects\n",
		*out, *rows, float64(info.Size())/1048576, float64(info.Size())/float64(*rows), *seed, *projects)
}
