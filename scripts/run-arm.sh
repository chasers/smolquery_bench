#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARM=${1:?usage: run-arm.sh <smolquery|clickhouse>}

VUS=${VUS:-4}
MODE=${MODE:-vus}
RATE=${RATE:-}
ROWS=${ROWS:-3062}
DURATION_S=${DURATION_S:-60}
WARMUP_S=${WARMUP_S:-20}
PAUSE_S=${PAUSE_S:-15}
BODY=${BODY:-$ROOT/bodies/eachrow.$ROWS.ndjson}
API_KEY=${API_KEY:-benchkey}
RESULTS=${RESULTS:-$ROOT/results/raw}
LABEL_SUFFIX=${LABEL_SUFFIX:-}

[ -f "$BODY" ] || { echo "body file missing: $BODY (run scripts/gen-bodies.sh)" >&2; exit 1; }

case $ARM in
  smolquery)
    URL="http://127.0.0.1:4000/v1/datasets/logs/tables/otel_logs/insert"
    CONTENT_TYPE="application/x-ndjson"
    AUTH="Bearer $API_KEY"
    SERVER_MATCH='beam.smp'
    ;;
  clickhouse)
    URL="http://127.0.0.1:8123/?query=INSERT%20INTO%20bench.otel_logs%20FORMAT%20JSONEachRow"
    CONTENT_TYPE="text/plain"
    AUTH=""
    SERVER_MATCH='clickhouse server'
    ;;
  *)
    echo "unknown arm: $ARM" >&2
    exit 1
    ;;
esac

if [ "$MODE" = rate ]; then
  [ -n "$RATE" ] || { echo "RATE is required when MODE=rate" >&2; exit 1; }
  LABEL="$ARM-rate$RATE$LABEL_SUFFIX"
else
  LABEL="$ARM-vus$VUS$LABEL_SUFFIX"
fi

mkdir -p "$RESULTS" "$ROOT/bin"
[ -x "$ROOT/bin/watch" ] || (cd "$ROOT" && go build -o bin/watch ./tools/watch)

echo "== $LABEL: preflight"
preflight=$(curl -sS -w '\n%{http_code}' -X POST "$URL" \
  -H "content-type: $CONTENT_TYPE" \
  ${AUTH:+-H "authorization: $AUTH"} \
  --data-binary @"$BODY")
status=$(tail -1 <<<"$preflight")
body_out=$(sed '$d' <<<"$preflight")
[ "$status" = 200 ] || { echo "preflight got HTTP $status: $body_out" >&2; exit 1; }
if [ -n "$body_out" ] && ! jq -e '(.insertErrors // []) | length == 0' <<<"$body_out" >/dev/null 2>&1; then
  echo "preflight rows were rejected: $body_out" >&2
  exit 1
fi

k6_env=(-e URL="$URL" -e BODY="$BODY" -e ROWS="$ROWS" -e MODE="$MODE"
        -e CONTENT_TYPE="$CONTENT_TYPE")
[ -n "$AUTH" ] && k6_env+=(-e AUTH="$AUTH")
if [ "$MODE" = rate ]; then
  k6_env+=(-e RATE="$RATE")
else
  k6_env+=(-e VUS="$VUS")
fi

echo "== $LABEL: warm-up ${WARMUP_S}s"
k6 run --quiet "${k6_env[@]}" -e DURATION="${WARMUP_S}s" "$ROOT/k6/insert.js" >/dev/null

echo "== $LABEL: pause ${PAUSE_S}s"
sleep "$PAUSE_S"

echo "== $LABEL: measuring ${DURATION_S}s"
"$ROOT/bin/watch" \
  -match "$SERVER_MATCH" -match 'k6 run' \
  -duration "$((DURATION_S + 8))s" \
  -out "$RESULTS/$LABEL.watch.json" &
watch_pid=$!

k6 run --quiet "${k6_env[@]}" \
  -e DURATION="${DURATION_S}s" \
  -e JSON_OUT="$RESULTS/$LABEL.k6.json" \
  "$ROOT/k6/insert.js"

wait "$watch_pid"
echo "== $LABEL: done → $RESULTS/$LABEL.{k6,watch}.json"
