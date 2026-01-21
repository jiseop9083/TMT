#!/bin/sh

DIR="$(cd "$(dirname "$0")" && pwd)"

sh "${DIR}/apply_metrics_server.sh"
sh "${DIR}/install_monitoring.sh"
sh "${DIR}/install_strimzi.sh"
sh "${DIR}/apply_cluster.sh"
sh "${DIR}/script.sh"