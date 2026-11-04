#!/bin/bash
set -euo pipefail

for attempt in $(seq 1 30); do
  if curl --fail --silent --show-error --max-time 5 \
      http://127.0.0.1:8080/actuator/health >/dev/null; then
    docker container inspect lucent-backend >/dev/null
    exit 0
  fi

  sleep 5
done

docker logs --tail 100 lucent-backend >&2 || true
exit 1
