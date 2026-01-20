#!/bin/sh

DIR="$(cd "$(dirname "$0")" && pwd)"

sh "${DIR}/install_strimzi.sh"
sh "${DIR}/apply_cluster.sh"
sh "${DIR}/script.sh"