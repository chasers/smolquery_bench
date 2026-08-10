#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
RUN_DIR=${RUN_DIR:-/tmp/sqbench}
DATA_DIR=${DATA_DIR:-$RUN_DIR/clickhouse-data}
PIDFILE=$RUN_DIR/clickhouse.pid
LOG=$RUN_DIR/clickhouse.log
FSYNC=${FSYNC:-1}

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
  cd "$DATA_DIR"
  nohup clickhouse server -- --path "$DATA_DIR" --listen_host 127.0.0.1 >"$LOG" 2>&1 &
  echo $! >"$PIDFILE"
)

echo "waiting for clickhouse on :8123 (log: $LOG)"
for i in $(seq 1 60); do
  [ "$(curl -fsS http://127.0.0.1:8123/ping 2>/dev/null)" = "Ok." ] && break
  if ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "clickhouse exited during boot; tail of $LOG:" >&2
    tail -20 "$LOG" >&2
    exit 1
  fi
  [ "$i" = 60 ] && { echo "timed out waiting for clickhouse" >&2; exit 1; }
  sleep 1
done

ch() { curl -fsS http://127.0.0.1:8123/ --data-binary "$1"; }

ch 'CREATE DATABASE IF NOT EXISTS bench'
curl -fsS http://127.0.0.1:8123/ --data-binary @"$ROOT/schemas/otel_logs.clickhouse.sql"

if [ "$FSYNC" = 1 ]; then
  ch 'ALTER TABLE bench.otel_logs MODIFY SETTING fsync_after_insert = 1, fsync_part_directory = 1'
fi

echo "clickhouse ready: $(ch 'SELECT version()') fsync=$FSYNC"
