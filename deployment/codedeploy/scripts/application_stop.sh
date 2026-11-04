#!/bin/bash
set -euo pipefail

if docker container inspect lucent-backend >/dev/null 2>&1; then
  docker stop --time 30 lucent-backend
  docker rm lucent-backend
fi
