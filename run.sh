#!/usr/bin/env bash
# Builds the orchestrator and runner, starts both, and runs the client once.
# Usage: ./run.sh [mkv|fmp4]
# Set NODE_DIR if the livepeer/node checkout is not at ../node.
set -euo pipefail
cd "$(dirname "$0")"

DEMO_DIR=$PWD
NODE_DIR=${NODE_DIR:-../node}

mkdir -p bin
(cd "$NODE_DIR" && go build -o "$DEMO_DIR/bin/" ./cmd/livepeer-orchestrator)
go build -o bin/runner runner.go

trap 'kill $(jobs -p) 2>/dev/null || true' EXIT
./bin/runner &
./bin/livepeer-orchestrator --config orchestrator.toml >orchestrator.log 2>&1 &

for _ in $(seq 1 50); do
  curl -sf http://127.0.0.1:8935/discovery >/dev/null && break
  sleep 0.2
done

./client.sh "${1:-mkv}"
