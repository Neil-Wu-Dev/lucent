# Lucent Monitoring Operations

## What monitoring collects

- AWS native EC2, ASG, ALB, and RDS metrics appear on the `Lucent-Production-Monitoring` dashboard.
- The optional CloudWatch Agent adds Backend Memory and root Disk metrics every 60 seconds in `Lucent/EC2`.
- The Agent reads only the currently running `lucent-backend` Docker container JSON log path and uploads it to `/lucent/backend/application` with seven-day retention.
- `NO DATA` in Memory or Disk widgets means the Agent is disabled or unavailable. It is not a healthy result.

## Enable or disable agent monitoring

1. Open **AWS Console → Systems Manager → Automation → Execute automation**.
2. Select `Lucent-Monitoring-ON` or `Lucent-Monitoring-OFF`.
3. Execute the runbook without entering EC2 instance IDs.
4. Review the Automation execution and the `Lucent-Backend-Monitoring-Convergence` State Manager Association compliance result.

The runtime state is `/lucent/monitoring/enabled`. ON/OFF targets every instance tagged `Service=lucent-backend`; the ASG propagates this tag to future scale-out and recovery instances. OFF stops the Agent and log upload but does not affect AWS native metrics, ALB health checks, CodeDeploy, Docker, or CPU target tracking.

## Alert notification verification

1. Set GitHub Repository Variable `LUCENT_MONITORING_ALERT_EMAIL` before running the manual Monitoring Infrastructure workflow.
2. Confirm the SNS email subscription from the message AWS sends to that address.
3. In CloudWatch, select an alarm and use **Actions → Set state → Alarm state** only for a non-destructive SNS email-path test. Restore the alarm state afterward.

## Safe deployment and rollback

- Use only **Actions → Monitoring Infrastructure → Run workflow** for monitoring resources. It shares the normal Terraform local state lock, performs a full plan, and rejects any non-monitoring resource change before apply.
- The existing `Infrastructure Pipeline` intentionally remains unchanged. Therefore, the first push of this Monitoring Terraform code to `main` will still follow the established `Infrastructure → Application CI/CD` chain. The manual Monitoring workflow is the controlled entry for later Monitoring-only Terraform changes and does not itself trigger Application CI/CD.
- Do not use `terraform apply -target`.
- If Agent collection causes a problem, run `Lucent-Monitoring-OFF`. This does not restart EC2 or the Backend container.
- If dashboard, alarms, or SNS need removal, make an approved Terraform change and use the same Monitoring workflow. Do not delete Terraform-managed monitoring resources manually.
