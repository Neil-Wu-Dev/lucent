# =========================
# Monitoring, Dashboard, and Alerts
# =========================
#
# This file is additive. It does not change the Backend Launch Template, ASG
# capacity, Scaling Policy, ALB, CodeDeploy, Docker, or application lifecycle.
# State Manager targets the existing Service=lucent-backend ASG tag, which is
# propagated to every current and future Backend instance.

data "aws_region" "current" {}

locals {
  monitoring_backend_service_tag = "lucent-backend"
  monitoring_namespace           = "Lucent/EC2"
  monitoring_enabled_parameter   = "/lucent/monitoring/enabled"
  monitoring_config_parameter    = "/lucent/monitoring/cloudwatch-agent-config"
}

resource "aws_sns_topic" "monitoring_alerts" {
  name = "lucent-production-alerts"

  tags = {
    Name    = "lucent-production-alerts"
    Service = "lucent-monitoring"
  }
}

resource "aws_sns_topic_subscription" "monitoring_alert_email" {
  count = trimspace(var.monitoring_alert_email) == "" ? 0 : 1

  topic_arn = aws_sns_topic.monitoring_alerts.arn
  protocol  = "email"
  endpoint  = trimspace(var.monitoring_alert_email)
}

resource "aws_cloudwatch_log_group" "backend_application" {
  name              = "/lucent/backend/application"
  retention_in_days = var.monitoring_log_retention_days

  tags = {
    Name    = "lucent-backend-application-logs"
    Service = "lucent-monitoring"
  }
}

# The value is a runtime control owned by the SSM ON/OFF runbooks. Terraform
# creates the parameter once but deliberately does not overwrite an operator's
# ON/OFF decision during later infrastructure applies.
resource "aws_ssm_parameter" "monitoring_enabled" {
  name  = local.monitoring_enabled_parameter
  type  = "String"
  value = tostring(var.monitoring_default_enabled)

  tags = {
    Name    = "lucent-monitoring-enabled"
    Service = "lucent-monitoring"
  }

  lifecycle {
    ignore_changes = [value]
  }
}

# The exact Docker JSON log path is discovered at State Manager execution time
# from the named lucent-backend container. This avoids collecting every Docker
# container on the host and adapts after CodeDeploy recreates that container.
resource "aws_ssm_parameter" "cloudwatch_agent_configuration" {
  name = local.monitoring_config_parameter
  type = "String"
  value = jsonencode({
    agent = {
      metrics_collection_interval = var.monitoring_agent_collection_interval_seconds
      run_as_user                 = "root"
    }
    metrics = {
      namespace = local.monitoring_namespace
      append_dimensions = {
        AutoScalingGroupName = "$${aws:AutoScalingGroupName}"
        InstanceId           = "$${aws:InstanceId}"
      }
      aggregation_dimensions = [["AutoScalingGroupName"]]
      metrics_collected = {
        mem = {
          measurement                 = ["mem_used_percent"]
          metrics_collection_interval = var.monitoring_agent_collection_interval_seconds
        }
        disk = {
          measurement                 = ["used_percent"]
          metrics_collection_interval = var.monitoring_agent_collection_interval_seconds
          resources                   = ["/"]
          ignore_file_system_types    = ["sysfs", "devtmpfs", "tmpfs", "overlay", "squashfs"]
        }
      }
    }
    logs = {
      logs_collected = {
        files = {
          collect_list = [
            {
              file_path       = "__LUCENT_BACKEND_LOG_PATH__"
              log_group_name  = aws_cloudwatch_log_group.backend_application.name
              log_stream_name = "{instance_id}/lucent-backend"
              timezone        = "UTC"
            }
          ]
        }
      }
    }
  })

  tags = {
    Name    = "lucent-cloudwatch-agent-configuration"
    Service = "lucent-monitoring"
  }
}

resource "aws_ssm_document" "monitoring_converge" {
  name            = "Lucent-Monitoring-Converge"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Non-critical Lucent CloudWatch Agent convergence for tagged Backend EC2 instances."
    parameters = {
      MonitoringEnabledParameter = {
        type    = "String"
        default = aws_ssm_parameter.monitoring_enabled.name
      }
      AgentConfigurationParameter = {
        type    = "String"
        default = aws_ssm_parameter.cloudwatch_agent_configuration.name
      }
    }
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "ConvergeCloudWatchAgent"
        inputs = {
          runCommand = [<<-SHELL
            #!/bin/bash
            set -euo pipefail

            fail() { echo "LUCENT_MONITORING_ERROR: $*" >&2; exit 1; }
            command -v aws >/dev/null 2>&1 || fail "AWS CLI is required for monitoring convergence"
            command -v flock >/dev/null 2>&1 || fail "flock is required for monitoring convergence"

            # Do not race the Launch Template bootstrap or any package operation.
            if command -v cloud-init >/dev/null 2>&1; then
              timeout 900 cloud-init status --wait || fail "cloud-init did not finish before monitoring convergence"
            fi
            exec 9>/var/lock/lucent-package-bootstrap.lock
            flock -w 900 9 || fail "timed out waiting for the Lucent package-installation lock"

            enabled=$(aws ssm get-parameter --name "{{ MonitoringEnabledParameter }}" --query Parameter.Value --output text --region ${data.aws_region.current.region})
            if [ "$enabled" != "true" ]; then
              systemctl disable --now amazon-cloudwatch-agent >/dev/null 2>&1 || true
              echo "LUCENT_MONITORING_DISABLED"
              exit 0
            fi

            if ! rpm -q amazon-cloudwatch-agent >/dev/null 2>&1; then
              dnf install -y amazon-cloudwatch-agent || fail "could not install amazon-cloudwatch-agent"
            fi

            config_dir=/opt/aws/amazon-cloudwatch-agent/etc/lucent
            template_file=$config_dir/agent-template.json
            config_file=$config_dir/agent.json
            install -d -m 0755 "$config_dir"
            aws ssm get-parameter --name "{{ AgentConfigurationParameter }}" --query Parameter.Value --output text --region ${data.aws_region.current.region} > "$template_file"

            log_path=$(docker inspect --format '{{.LogPath}}' lucent-backend 2>/dev/null || true)
            if [ -z "$log_path" ] || [ ! -f "$log_path" ]; then
              log_path=/var/log/lucent/backend-container-unavailable.log
            fi
            sed "s|__LUCENT_BACKEND_LOG_PATH__|$log_path|g" "$template_file" > "$config_file"

            /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
              -a fetch-config -m ec2 -c "file:$config_file" -s || fail "could not start amazon-cloudwatch-agent"
            systemctl is-active --quiet amazon-cloudwatch-agent || fail "amazon-cloudwatch-agent is not active"
            echo "LUCENT_MONITORING_ENABLED"
          SHELL
          ]
        }
      }
    ]
  })
}

# State Manager continuously converges both existing and future Backend ASG
# instances by their stable propagated Service tag. Association failures are
# visible in Systems Manager compliance and never block Docker or CodeDeploy.
resource "aws_ssm_association" "backend_monitoring_convergence" {
  name                = aws_ssm_document.monitoring_converge.name
  association_name    = "Lucent-Backend-Monitoring-Convergence"
  schedule_expression = "rate(30 minutes)"
  compliance_severity = "HIGH"
  max_concurrency     = "50%"
  max_errors          = "0"

  targets {
    key    = "tag:Service"
    values = [local.monitoring_backend_service_tag]
  }

  parameters = {
    MonitoringEnabledParameter  = aws_ssm_parameter.monitoring_enabled.name
    AgentConfigurationParameter = aws_ssm_parameter.cloudwatch_agent_configuration.name
  }
}

data "aws_iam_policy_document" "monitoring_automation_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "monitoring_automation" {
  name               = "lucent-monitoring-automation-role"
  assume_role_policy = data.aws_iam_policy_document.monitoring_automation_assume_role.json

  tags = {
    Name    = "lucent-monitoring-automation-role"
    Service = "lucent-monitoring"
  }
}

resource "aws_iam_role_policy" "monitoring_automation" {
  name = "lucent-monitoring-automation-runtime"
  role = aws_iam_role.monitoring_automation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SetLucentMonitoringRuntimeState"
        Effect   = "Allow"
        Action   = ["ssm:PutParameter"]
        Resource = aws_ssm_parameter.monitoring_enabled.arn
      },
      {
        Sid      = "RunLucentMonitoringConvergenceDocument"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = aws_ssm_document.monitoring_converge.arn
      },
      {
        Sid      = "TargetOnlyLucentBackendInstances"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/*"
        Condition = {
          StringEquals = {
            "ssm:resourceTag/Service" = local.monitoring_backend_service_tag
          }
        }
      },
      {
        Sid      = "ReadMonitoringCommandProgress"
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation"]
        Resource = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:managed-instance/*"
      }
    ]
  })
}

resource "aws_ssm_document" "monitoring_on" {
  name            = "Lucent-Monitoring-ON"
  document_type   = "Automation"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "Enable Lucent CloudWatch Agent metrics and Backend application log collection on tagged Backend EC2 instances."
    assumeRole    = aws_iam_role.monitoring_automation.arn
    mainSteps = [
      {
        name   = "EnableMonitoringRuntimeState"
        action = "aws:executeAwsApi"
        inputs = {
          Service   = "ssm"
          Api       = "PutParameter"
          Name      = aws_ssm_parameter.monitoring_enabled.name
          Value     = "true"
          Type      = "String"
          Overwrite = true
        }
      },
      {
        name   = "ConvergeCurrentBackendInstances"
        action = "aws:runCommand"
        inputs = {
          DocumentName = aws_ssm_document.monitoring_converge.name
          Targets = [
            {
              Key    = "tag:Service"
              Values = [local.monitoring_backend_service_tag]
            }
          ]
          Parameters = {
            MonitoringEnabledParameter  = aws_ssm_parameter.monitoring_enabled.name
            AgentConfigurationParameter = aws_ssm_parameter.cloudwatch_agent_configuration.name
          }
          MaxErrors = "0"
        }
      }
    ]
  })
}

resource "aws_ssm_document" "monitoring_off" {
  name            = "Lucent-Monitoring-OFF"
  document_type   = "Automation"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "Disable Lucent CloudWatch Agent metrics and Backend application log collection on tagged Backend EC2 instances."
    assumeRole    = aws_iam_role.monitoring_automation.arn
    mainSteps = [
      {
        name   = "DisableMonitoringRuntimeState"
        action = "aws:executeAwsApi"
        inputs = {
          Service   = "ssm"
          Api       = "PutParameter"
          Name      = aws_ssm_parameter.monitoring_enabled.name
          Value     = "false"
          Type      = "String"
          Overwrite = true
        }
      },
      {
        name   = "ConvergeCurrentBackendInstances"
        action = "aws:runCommand"
        inputs = {
          DocumentName = aws_ssm_document.monitoring_converge.name
          Targets = [
            {
              Key    = "tag:Service"
              Values = [local.monitoring_backend_service_tag]
            }
          ]
          Parameters = {
            MonitoringEnabledParameter  = aws_ssm_parameter.monitoring_enabled.name
            AgentConfigurationParameter = aws_ssm_parameter.cloudwatch_agent_configuration.name
          }
          MaxErrors = "0"
        }
      }
    ]
  })
}

resource "aws_cloudwatch_dashboard" "production_monitoring" {
  dashboard_name = "Lucent-Production-Monitoring"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = "# Lucent Production Monitoring\nMemory and Disk use the `Lucent/EC2` CloudWatch Agent namespace. **NO DATA means the agent is disabled or unavailable; it does not mean the Backend is healthy.**"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 2
        width  = 12
        height = 6
        properties = {
          title  = "Backend EC2 CPU, Network, and Status Checks"
          region = data.aws_region.current.region
          period = 300
          stat   = "Average"
          metrics = [
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", aws_autoscaling_group.backend.name],
            [".", "NetworkIn", ".", "."],
            [".", "NetworkOut", ".", "."],
            [".", "StatusCheckFailed", ".", ".", { stat = "Maximum" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 2
        width  = 12
        height = 6
        properties = {
          title  = "Backend ASG Capacity"
          region = data.aws_region.current.region
          period = 60
          stat   = "Average"
          metrics = [
            ["AWS/AutoScaling", "GroupDesiredCapacity", "AutoScalingGroupName", aws_autoscaling_group.backend.name],
            [".", "GroupInServiceInstances", ".", "."],
            [".", "GroupTotalCapacity", ".", "."]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 8
        width  = 12
        height = 6
        properties = {
          title  = "Backend Memory and Root Disk (CloudWatch Agent)"
          region = data.aws_region.current.region
          period = var.monitoring_agent_collection_interval_seconds
          stat   = "Average"
          metrics = [
            [local.monitoring_namespace, "mem_used_percent", "AutoScalingGroupName", aws_autoscaling_group.backend.name],
            [".", "disk_used_percent", ".", "."]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 8
        width  = 12
        height = 6
        properties = {
          title  = "ALB Target Health and HTTP"
          region = data.aws_region.current.region
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", aws_lb_target_group.backend.arn_suffix, "LoadBalancer", aws_lb.backend.arn_suffix, { stat = "Average" }],
            [".", "UnHealthyHostCount", ".", ".", ".", ".", { stat = "Maximum" }],
            [".", "RequestCount", "LoadBalancer", aws_lb.backend.arn_suffix],
            [".", "HTTPCode_Target_5XX_Count", "TargetGroup", aws_lb_target_group.backend.arn_suffix, "LoadBalancer", aws_lb.backend.arn_suffix],
            [".", "HTTPCode_ELB_5XX_Count", "LoadBalancer", aws_lb.backend.arn_suffix],
            [".", "TargetResponseTime", "TargetGroup", aws_lb_target_group.backend.arn_suffix, "LoadBalancer", aws_lb.backend.arn_suffix, { stat = "Average" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 14
        width  = 24
        height = 6
        properties = {
          title  = "PostgreSQL RDS"
          region = data.aws_region.current.region
          period = 60
          stat   = "Average"
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.lucent.id],
            [".", "DatabaseConnections", ".", "."],
            [".", "FreeStorageSpace", ".", ".", { stat = "Minimum" }],
            [".", "ReadLatency", ".", "."],
            [".", "WriteLatency", ".", "."]
          ]
        }
      }
    ]
  })
}

resource "aws_cloudwatch_metric_alarm" "backend_high_cpu" {
  alarm_name          = "lucent-backend-high-cpu"
  alarm_description   = "Backend ASG average EC2 CPU is at or above 80 percent."
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.monitoring_alerts.arn]
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.backend.name
  }
}

resource "aws_cloudwatch_metric_alarm" "backend_high_memory" {
  alarm_name          = "lucent-backend-high-memory"
  alarm_description   = "Backend ASG average memory utilization is at or above 80 percent. No data is non-breaching because monitoring can be intentionally disabled."
  namespace           = local.monitoring_namespace
  metric_name         = "mem_used_percent"
  statistic           = "Average"
  period              = var.monitoring_agent_collection_interval_seconds
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.monitoring_alerts.arn]
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.backend.name
  }
}

resource "aws_cloudwatch_metric_alarm" "backend_high_disk" {
  alarm_name          = "lucent-backend-high-disk"
  alarm_description   = "Backend ASG average root disk utilization is at or above 85 percent. No data is non-breaching because monitoring can be intentionally disabled."
  namespace           = local.monitoring_namespace
  metric_name         = "disk_used_percent"
  statistic           = "Maximum"
  period              = var.monitoring_agent_collection_interval_seconds
  evaluation_periods  = 3
  threshold           = 85
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.monitoring_alerts.arn]
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.backend.name
  }
}

resource "aws_cloudwatch_metric_alarm" "backend_unhealthy" {
  alarm_name          = "lucent-backend-unhealthy-target"
  alarm_description   = "At least one Backend ALB target is unhealthy."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.monitoring_alerts.arn]
  dimensions = {
    TargetGroup  = aws_lb_target_group.backend.arn_suffix
    LoadBalancer = aws_lb.backend.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "backend_service_unavailable" {
  alarm_name          = "lucent-backend-service-unavailable"
  alarm_description   = "No healthy Backend targets are available through the ALB."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.monitoring_alerts.arn]
  dimensions = {
    TargetGroup  = aws_lb_target_group.backend.arn_suffix
    LoadBalancer = aws_lb.backend.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "backend_http_5xx" {
  alarm_name          = "lucent-backend-http-5xx"
  alarm_description   = "Backend targets returned at least five HTTP 5xx responses in one minute."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.monitoring_alerts.arn]
  dimensions = {
    TargetGroup  = aws_lb_target_group.backend.arn_suffix
    LoadBalancer = aws_lb.backend.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_high_cpu" {
  alarm_name          = "lucent-rds-high-cpu"
  alarm_description   = "Lucent PostgreSQL CPU is at or above 80 percent."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.monitoring_alerts.arn]
  dimensions = {
    DBInstanceIdentifier = aws_db_instance.lucent.id
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_low_free_storage" {
  alarm_name          = "lucent-rds-low-free-storage"
  alarm_description   = "Lucent PostgreSQL free storage is below 2 GiB."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2147483648
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.monitoring_alerts.arn]
  dimensions = {
    DBInstanceIdentifier = aws_db_instance.lucent.id
  }
}
