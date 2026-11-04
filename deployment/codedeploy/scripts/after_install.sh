#!/bin/bash
set -euo pipefail

source /opt/lucent/codedeploy/deployment.env

test -n "${LUCENT_AWS_REGION:?}"
test -n "${LUCENT_BACKEND_IMAGE:?}"
test -n "${LUCENT_DATABASE_SECRET_ARN:?}"

aws secretsmanager get-secret-value \
  --region "$LUCENT_AWS_REGION" \
  --secret-id "$LUCENT_DATABASE_SECRET_ARN" \
  --query SecretString \
  --output text > /etc/lucent/backend.env
chmod 0600 /etc/lucent/backend.env

REGISTRY="${LUCENT_BACKEND_IMAGE%%/*}"
aws ecr get-login-password --region "$LUCENT_AWS_REGION" | \
  docker login --username AWS --password-stdin "$REGISTRY"
docker pull "$LUCENT_BACKEND_IMAGE"
docker image inspect "$LUCENT_BACKEND_IMAGE" >/dev/null
