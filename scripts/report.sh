#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
RESULTS=${RESULTS:-$ROOT/results/raw}

shopt -s nullglob
files=("$RESULTS"/*.k6.json)
[ ${#files[@]} -gt 0 ] || { echo "no results in $RESULTS" >&2; exit 1; }

printf '| run | rows/s | p50 ms | p95 ms | p99 ms | refused | server cpu avg %% | server cpu peak %% | server rss peak MB |\n'
printf '|---|---|---|---|---|---|---|---|---|\n'

for f in "${files[@]}"; do
  label=$(basename "${f%.k6.json}")
  watch="$RESULTS/$label.watch.json"
  if [ -f "$watch" ]; then
    server=$(jq -r '.processes[0] | "\(.cpu_avg_pct|round) | \(.cpu_peak_pct|round) | \(.rss_peak_mb|round)"' "$watch")
  else
    server="- | - | -"
  fi
  jq -r --arg label "$label" --arg server "$server" '
    "| \($label) | \(.rows_per_s|round) | \(.latency_ms.med|round) | \(.latency_ms.p95|round) | \(.latency_ms.p99|round) | \(.requests_refused) | \($server) |"
  ' "$f"
done
