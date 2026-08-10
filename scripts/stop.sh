#!/usr/bin/env bash
set -euo pipefail

RUN_DIR=${RUN_DIR:-/tmp/sqbench}
ARMS=${1:-smolquery clickhouse}

for arm in $ARMS; do
  pidfile=$RUN_DIR/$arm.pid
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    kill "$(cat "$pidfile")"
    echo "stopped $arm ($(cat "$pidfile"))"
  fi
  rm -f "$pidfile"
done
