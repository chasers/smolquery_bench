#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARM=${1:?usage: sweep.sh <smolquery|clickhouse>}
VUS_LIST=${VUS_LIST:-1 4 8 16 32}

for vus in $VUS_LIST; do
  "$ROOT/scripts/setup-$ARM.sh"
  VUS=$vus "$ROOT/scripts/run-arm.sh" "$ARM"
done

"$ROOT/scripts/stop.sh" "$ARM"
"$ROOT/scripts/report.sh"
