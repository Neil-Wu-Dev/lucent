#!/bin/bash
set -euo pipefail

systemctl enable --now docker
install -d -m 0700 /etc/lucent
test -f /opt/lucent/codedeploy/deployment.env
