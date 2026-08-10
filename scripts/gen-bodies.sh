#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT_DIR=${OUT_DIR:-$ROOT/bodies}
ROWS=${ROWS:-3062}
PROJECTS=${PROJECTS:-1000}
SEED=${SEED:-42}

cd "$ROOT"
go run ./tools/genbody \
  -rows "$ROWS" \
  -projects "$PROJECTS" \
  -seed "$SEED" \
  -out "$OUT_DIR/eachrow.$ROWS.ndjson"
