#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SMOLQUERY_DIR=${SMOLQUERY_DIR:-$HOME/Dev/supabase/smolquery}
RUN_DIR=${RUN_DIR:-/tmp/sqbench}
DATA_DIR=${DATA_DIR:-$RUN_DIR/smolquery-data}
API_KEY=${API_KEY:-benchkey}
PIDFILE=$RUN_DIR/smolquery.pid
LOG=$RUN_DIR/smolquery.log

FLUSH_MAX_BYTES=${FLUSH_MAX_BYTES:-33554432}
FLUSH_INTERVAL_MS=${FLUSH_INTERVAL_MS:-1000}
MAX_BUFFERED_BYTES=${MAX_BUFFERED_BYTES:-134217728}
WRITE_POOL_SIZE=${WRITE_POOL_SIZE:-4}
ENCODE_CONCURRENCY=${ENCODE_CONCURRENCY:-4}
FLUSH_WRITER=${FLUSH_WRITER:-duckdb}

mkdir -p "$RUN_DIR"

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  kill "$(cat "$PIDFILE")"
  for _ in $(seq 1 30); do
    kill -0 "$(cat "$PIDFILE")" 2>/dev/null || break
    sleep 1
  done
fi
rm -f "$PIDFILE"
rm -rf "$DATA_DIR"
mkdir -p "$DATA_DIR"

(
  cd "$SMOLQUERY_DIR"
  SMOLQUERY_DATA_DIR="$DATA_DIR" \
  SMOLQUERY_API_KEY="$API_KEY" \
  SMOLQUERY_FLUSH_MAX_BYTES="$FLUSH_MAX_BYTES" \
  SMOLQUERY_FLUSH_INTERVAL_MS="$FLUSH_INTERVAL_MS" \
  SMOLQUERY_MAX_BUFFERED_BYTES="$MAX_BUFFERED_BYTES" \
  SMOLQUERY_WRITE_POOL_SIZE="$WRITE_POOL_SIZE" \
  SMOLQUERY_ENCODE_CONCURRENCY="$ENCODE_CONCURRENCY" \
  SMOLQUERY_FLUSH_WRITER="$FLUSH_WRITER" \
  nohup mix run --no-halt >"$LOG" 2>&1 &
  echo $! >"$PIDFILE"
)

echo "waiting for smolquery on :4000 (log: $LOG)"
for i in $(seq 1 180); do
  curl -fsS -o /dev/null http://127.0.0.1:4000/healthz 2>/dev/null && break
  if ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "smolquery exited during boot; tail of $LOG:" >&2
    tail -20 "$LOG" >&2
    exit 1
  fi
  [ "$i" = 180 ] && { echo "timed out waiting for smolquery" >&2; exit 1; }
  sleep 1
done

auth=(-H "authorization: Bearer $API_KEY")
json=(-H "content-type: application/json")

curl -fsS "${auth[@]}" "${json[@]}" -o /dev/null \
  -X POST http://127.0.0.1:4000/v1/datasets -d '{"id":"logs"}'
curl -fsS "${auth[@]}" "${json[@]}" -o /dev/null \
  -X POST http://127.0.0.1:4000/v1/datasets/logs/tables \
  --data-binary @"$ROOT/schemas/otel_logs.smolquery.json"
curl -fsS "${auth[@]}" "${json[@]}" -o /dev/null \
  -X PATCH http://127.0.0.1:4000/v1/datasets/logs/tables/otel_logs \
  -d '{"clustering":["project_id","timestamp"]}'

echo "smolquery ready: flush_max_bytes=$FLUSH_MAX_BYTES flush_interval_ms=$FLUSH_INTERVAL_MS write_pool_size=$WRITE_POOL_SIZE encode_concurrency=$ENCODE_CONCURRENCY writer=$FLUSH_WRITER"
