#!/bin/bash
set -euo pipefail

source /opt/lucent/codedeploy/deployment.env

docker run -d \
  --name lucent-backend \
  --restart unless-stopped \
  --env-file /etc/lucent/backend.env \
  --label "lucent.release.image=${LUCENT_BACKEND_IMAGE}" \
  --label "lucent.release.revision=${LUCENT_REVISION_ID}" \
  -p 8080:8080 \
  "$LUCENT_BACKEND_IMAGE"
