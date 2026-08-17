import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';

const INSERTED_AT_PLACEHOLDER = '____INSERTED_AT___________';
const STAMP_WIDTH = INSERTED_AT_PLACEHOLDER.length;

const bodyBytes = new Uint8Array(open(__ENV.BODY, 'b'));
const stampOffsets = findStampOffsets(bodyBytes);
const stampsRows = stampOffsets.length > 0;
const stampBytes = new Uint8Array(STAMP_WIDTH);
const rows = parseInt(__ENV.ROWS || '0', 10);
if (!__ENV.URL && !__ENV.URLS) throw new Error('URL or URLS is required');
if (!rows) throw new Error('ROWS is required');

const urls = (__ENV.URLS || __ENV.URL)
  .split(',')
  .map((u) => u.trim())
  .filter((u) => u !== '');
if (urls.length === 0) throw new Error('URLS resolved to nothing');

function urlForVu() {
  return urls[(__VU - 1) % urls.length];
}

const expectStatus = parseInt(__ENV.EXPECT_STATUS || '200', 10);
const mode = __ENV.MODE || 'vus';
const duration = __ENV.DURATION || '30s';
const gracefulStop = __ENV.GRACEFUL_STOP || '5s';

function nowIso() {
  return new Date().toISOString().replace('Z', '000');
}

function findStampOffsets(bytes) {
  const pattern = new Uint8Array(STAMP_WIDTH);
  for (let i = 0; i < STAMP_WIDTH; i++) {
    pattern[i] = INSERTED_AT_PLACEHOLDER.charCodeAt(i);
  }

  const offsets = [];
  const limit = bytes.length - STAMP_WIDTH;
  for (let i = 0; i <= limit; i++) {
    if (bytes[i] !== pattern[0]) continue;
    let j = 1;
    while (j < STAMP_WIDTH && bytes[i + j] === pattern[j]) j++;
    if (j === STAMP_WIDTH) {
      offsets.push(i);
      i += STAMP_WIDTH - 1;
    }
  }
  return offsets;
}

function stampBody() {
  const iso = nowIso();
  if (iso.length !== STAMP_WIDTH) {
    throw new Error(`stamp is ${iso.length} bytes, expected ${STAMP_WIDTH}: ${iso}`);
  }
  for (let i = 0; i < STAMP_WIDTH; i++) stampBytes[i] = iso.charCodeAt(i);
  for (let k = 0; k < stampOffsets.length; k++) {
    bodyBytes.set(stampBytes, stampOffsets[k]);
  }
}

const rowsAccepted = new Counter('rows_accepted');
const requestsRefused = new Counter('requests_refused');
const acceptLatency = new Trend('accept_latency', true);

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
  if (stampsRows) stampBody();
  const res = http.post(urlForVu(), bodyBytes.buffer, params);
  if (res.status === expectStatus) {
    rowsAccepted.add(rows);
    acceptLatency.add(res.timings.duration);
  } else {
    requestsRefused.add(1);
    if (res.status === 429) {
      const retryAfter = parseFloat(res.headers['Retry-After']);
      sleep(Math.min(isNaN(retryAfter) ? 0.5 : retryAfter, 2));
    }
  }
  check(res, { 'expected status': (r) => r.status === expectStatus });
}

export function handleSummary(data) {
  const durationS = data.state.testRunDurationMs / 1000;
  const latency = data.metrics.accept_latency
    ? data.metrics.accept_latency.values
    : {};
  const accepted = data.metrics.rows_accepted
    ? data.metrics.rows_accepted.values.count
    : 0;
  const refused = data.metrics.requests_refused
    ? data.metrics.requests_refused.values.count
    : 0;

  const summary = {
    inserted_at: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
    url: urls[0],
    urls,
    targets: urls.length,
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
