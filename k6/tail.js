import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';

if (!__ENV.URLS) throw new Error('URLS is required');
if (!__ENV.TABLE) throw new Error('TABLE is required');
if (!__ENV.PROJECTS) throw new Error('PROJECTS is required');

const urls = __ENV.URLS.split(',').map((u) => u.trim()).filter((u) => u !== '');
const projects = __ENV.PROJECTS.split(',').map((p) => p.trim()).filter((p) => p !== '');
const table = __ENV.TABLE;
const limit = parseInt(__ENV.LIMIT || '100', 10);
const orderColumn = __ENV.ORDER_COLUMN || 'inserted_at';
const duration = __ENV.DURATION || '60s';
const vus = parseInt(__ENV.VUS || `${projects.length}`, 10);
const thinkS = parseFloat(__ENV.SLEEP_S || '0');
const timeoutMs = parseInt(__ENV.TIMEOUT_MS || '30000', 10);
const modes = (__ENV.MODES || 'distributed,single').split(',').map((m) => m.trim());
const columns = __ENV.COLUMNS || 'timestamp, trace_id, span_id, body';
const windowS = parseInt(__ENV.WINDOW_S || '300', 10);

export const options = {
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
  scenarios: {
    tail: { executor: 'constant-vus', vus, duration, gracefulStop: '30s' },
  },
};

const wall = {};
const engine = {};
const rowsReturned = {};
const shards = {};
const hotFiles = {};
const queries = {};
const errors = {};
const short = {};
const errStatus = {};
for (const code of ['0', '4xx', '5xx', 'decode', 'job']) {
  errStatus[code] = new Counter(`tail_err_${code}`);
}
let reported = 0;
for (const mode of modes) {
  wall[mode] = new Trend(`tail_wall_${mode}`, true);
  engine[mode] = new Trend(`tail_duration_${mode}`, true);
  rowsReturned[mode] = new Trend(`tail_rows_${mode}`);
  shards[mode] = new Trend(`tail_shards_${mode}`);
  hotFiles[mode] = new Trend(`tail_hot_files_${mode}`);
  queries[mode] = new Counter(`tail_queries_${mode}`);
  errors[mode] = new Counter(`tail_errors_${mode}`);
  short[mode] = new Counter(`tail_short_${mode}`);
}

const params = { headers: { 'content-type': 'application/json' }, timeout: `${timeoutMs + 10000}ms` };
if (__ENV.AUTH) params.headers['authorization'] = __ENV.AUTH;

function cutoff() {
  const t = new Date(Date.now() - windowS * 1000).toISOString();
  return t.slice(0, 19).replace('T', ' ');
}

function sqlFor(project) {
  const window = windowS > 0 ? ` AND ${orderColumn} >= TIMESTAMP '${cutoff()}'` : '';
  return (
    `SELECT ${columns} FROM ${table} WHERE project = '${project}'${window} ` +
    `ORDER BY ${orderColumn} DESC LIMIT ${limit}`
  );
}

export default function () {
  const project = projects[(__VU - 1) % projects.length];
  const url = urls[(__VU - 1 + __ITER) % urls.length];
  const mode = modes[__ITER % modes.length];
  const body = JSON.stringify({
    query: sqlFor(project),
    options: { distributed: mode === 'distributed' },
    maxResults: limit,
    timeoutMs,
  });

  const res = http.post(url, body, params);
  queries[mode].add(1);

  let decoded = null;
  if (res.status === 200) {
    try {
      decoded = res.json();
    } catch (e) {
      decoded = null;
    }
  }

  const ok = decoded !== null && decoded.job && decoded.job.error === null;
  if (ok) {
    const job = decoded.job;
    const rows = Array.isArray(decoded.rows) ? decoded.rows.length : 0;
    wall[mode].add(res.timings.duration);
    if (typeof job.durationMs === 'number') engine[mode].add(job.durationMs);
    rowsReturned[mode].add(rows);
    shards[mode].add(job.scatter && job.scatter.shards ? job.scatter.shards : 0);
    const hot = job.statistics && job.statistics.hot ? job.statistics.hot.filesTotal : null;
    if (typeof hot === 'number') hotFiles[mode].add(hot);
    if (rows < limit) short[mode].add(1);
  } else {
    errors[mode].add(1);
    const cls =
      res.status === 0 ? '0' : res.status >= 500 ? '5xx' : res.status >= 400 ? '4xx' : decoded === null ? 'decode' : 'job';
    errStatus[cls].add(1);
    if (reported < 5) {
      reported += 1;
      console.error(`tail error ${mode} ${project} status=${res.status} ${String(res.body).slice(0, 300)}`);
    }
  }
  check(res, { 'query ok': () => ok });
  if (thinkS > 0) sleep(thinkS);
}

function values(data, name) {
  return data.metrics[name] ? data.metrics[name].values : {};
}

export function handleSummary(data) {
  const summary = {
    inserted_at: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
    table,
    projects,
    vus,
    limit,
    order_column: orderColumn,
    columns,
    window_s: windowS,
    duration_s: data.state.testRunDurationMs / 1000,
    think_s: thinkS,
    urls,
    modes: {},
    error_classes: {},
  };
  for (const code of ['0', '4xx', '5xx', 'decode', 'job']) {
    summary.error_classes[code] = values(data, `tail_err_${code}`).count || 0;
  }
  for (const mode of modes) {
    const w = values(data, `tail_wall_${mode}`);
    const d = values(data, `tail_duration_${mode}`);
    summary.modes[mode] = {
      queries: values(data, `tail_queries_${mode}`).count || 0,
      errors: values(data, `tail_errors_${mode}`).count || 0,
      short_results: values(data, `tail_short_${mode}`).count || 0,
      wall_ms: { min: w.min, med: w.med, p90: w['p(90)'], p95: w['p(95)'], p99: w['p(99)'], max: w.max, avg: w.avg },
      duration_ms: { med: d.med, p95: d['p(95)'], max: d.max },
      rows_med: values(data, `tail_rows_${mode}`).med,
      shards_med: values(data, `tail_shards_${mode}`).med,
      shards_max: values(data, `tail_shards_${mode}`).max,
      hot_files_med: values(data, `tail_hot_files_${mode}`).med,
      hot_files_max: values(data, `tail_hot_files_${mode}`).max,
    };
  }
  const out = {};
  if (__ENV.JSON_OUT) out[__ENV.JSON_OUT] = JSON.stringify(summary, null, 2) + '\n';
  out.stdout =
    modes
      .map((m) => {
        const s = summary.modes[m];
        return `${m}: ${s.queries} queries, ${s.errors} errors, wall p50 ${fmt(s.wall_ms.med)}ms p95 ${fmt(s.wall_ms.p95)}ms p99 ${fmt(s.wall_ms.p99)}ms, rows ${s.rows_med}, shards ${s.shards_med}`;
      })
      .join('\n') + '\n';
  return out;
}

function fmt(v) {
  return typeof v === 'number' ? v.toFixed(1) : '?';
}
