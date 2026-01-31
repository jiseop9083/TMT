#!/bin/sh

DIR="$(cd "$(dirname "$0")/.." && pwd)/benchmarks"

sh "${DIR}/run.sh" --auto-create-topics=false
