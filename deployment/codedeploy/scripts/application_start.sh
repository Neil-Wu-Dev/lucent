#!/bin/bash
set -euo pipefail

source /opt/lucent/codedeploy/deployment.env

# ApplicationStop is not run for a first deployment. A previous manual or
# pre-CodeDeploy container can therefore still occupy this name and port.
# If it exists, Docker must remove it successfully before the replacement
# starts; failures are intentionally not suppressed.
if docker container inspect lucent-backend >/dev/null 2>&1; then
  docker rm --force lucent-backend
fi

docker run -d \
  --name lucent-backend \
  --restart unless-stopped \
  --env-file /etc/lucent/backend.env \
  --label "lucent.release.image=${LUCENT_BACKEND_IMAGE}" \
  --label "lucent.release.revision=${LUCENT_REVISION_ID}" \
  -p 8080:8080 \
  "$LUCENT_BACKEND_IMAGE"
