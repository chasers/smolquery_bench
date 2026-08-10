import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

const body = open(__ENV.BODY, 'b');
const rows = parseInt(__ENV.ROWS || '0', 10);
if (!__ENV.URL) throw new Error('URL is required');
if (!rows) throw new Error('ROWS is required');

const expectStatus = parseInt(__ENV.EXPECT_STATUS || '200', 10);
const mode = __ENV.MODE || 'vus';
const duration = __ENV.DURATION || '30s';
const gracefulStop = __ENV.GRACEFUL_STOP || '5s';

const rowsAccepted = new Counter('rows_accepted');
const requestsRefused = new Counter('requests_refused');

function scenario() {
  if (mode === 'rate') {
    const rate = parseInt(__ENV.RATE, 10);
    if (!rate) throw new Error('RATE is required when MODE=rate');
    return {
      executor: 'constant-arrival-rate',
      rate,
      timeUnit: '1s',
      duration,
      preAllocatedVUs: Math.min(2 * rate, 256),
      maxVUs: parseInt(__ENV.MAX_VUS || `${2 * rate}`, 10),
      gracefulStop,
    };
  }
  return {
    executor: 'constant-vus',
    vus: parseInt(__ENV.VUS || '4', 10),
    duration,
    gracefulStop,
  };
}

export const options = {
  discardResponseBodies: true,
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
  scenarios: { insert: scenario() },
};

const params = {
  headers: { 'content-type': __ENV.CONTENT_TYPE || 'application/x-ndjson' },
  timeout: __ENV.TIMEOUT || '120s',
};
if (__ENV.AUTH) params.headers['authorization'] = __ENV.AUTH;

export default function () {
  const res = http.post(__ENV.URL, body, params);
  if (res.status === expectStatus) {
    rowsAccepted.add(rows);
  } else {
    requestsRefused.add(1);
  }
  check(res, { 'expected status': (r) => r.status === expectStatus });
}

export function handleSummary(data) {
  const durationS = data.state.testRunDurationMs / 1000;
  const latency = data.metrics.http_req_duration
    ? data.metrics.http_req_duration.values
    : {};
  const accepted = data.metrics.rows_accepted
    ? data.metrics.rows_accepted.values.count
    : 0;
  const refused = data.metrics.requests_refused
    ? data.metrics.requests_refused.values.count
    : 0;

  const summary = {
    url: __ENV.URL,
    mode,
    vus: mode === 'vus' ? parseInt(__ENV.VUS || '4', 10) : null,
    rate: mode === 'rate' ? parseInt(__ENV.RATE, 10) : null,
    duration_s: durationS,
    rows_per_request: rows,
    requests: data.metrics.http_reqs ? data.metrics.http_reqs.values.count : 0,
    rows_accepted: accepted,
    rows_per_s: durationS > 0 ? accepted / durationS : 0,
    requests_refused: refused,
    latency_ms: {
      med: latency.med,
      p90: latency['p(90)'],
      p95: latency['p(95)'],
      p99: latency['p(99)'],
      avg: latency.avg,
      max: latency.max,
    },
    data_sent_mib: data.metrics.data_sent
      ? data.metrics.data_sent.values.count / 1048576
      : 0,
  };

  const text =
    `\n${summary.rows_per_s.toFixed(0)} rows/s ` +
    `(${summary.requests} reqs, ${refused} refused) ` +
    `p50 ${Number(latency.med || 0).toFixed(1)}ms ` +
    `p95 ${Number(latency['p(95)'] || 0).toFixed(1)}ms ` +
    `p99 ${Number(latency['p(99)'] || 0).toFixed(1)}ms\n`;

  const out = { stdout: text };
  if (__ENV.JSON_OUT) out[__ENV.JSON_OUT] = JSON.stringify(summary, null, 2) + '\n';
  return out;
}
