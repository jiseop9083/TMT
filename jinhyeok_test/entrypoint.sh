#!/bin/bash
set -e

exec java \
  -agentpath:/async-profiler/build/libasyncProfiler.so=event=wall,file=/profiles/async-${HOSTNAME}.html \
  -cp "/app/*" \
  ProducerOnce