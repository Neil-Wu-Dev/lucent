# =========================
# Backend CodeDeploy
# =========================
#
# Stage A uses the existing Backend ASG instance tags for the first controlled
# release. Stage B is enabled only through an explicit variable after that
# release succeeds; CodeDeploy then manages ASG launch lifecycle deployments.

resource "aws_secretsmanager_secret" "backend_database_runtime" {
  name        = "lucent-backend-database-runtime"
  description = "Runtime database environment for the Lucent Backend CodeDeploy hooks."

  tags = {
    Name = "lucent-backend-database-runtime"
  }
}

resource "aws_secretsmanager_secret_version" "backend_database_runtime" {
  secret_id = aws_secretsmanager_secret.backend_database_runtime.id

  secret_string = join("\n", [
    "DB_URL=jdbc:postgresql://${aws_db_instance.lucent.address}:${aws_db_instance.lucent.port}/${var.database_name}",
    "DB_USERNAME=${var.database_username}",
    "DB_PASSWORD=${var.database_password}"
  ])
}

data "aws_iam_policy_document" "codedeploy_service_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codedeploy_service" {
  name               = "lucent-codedeploy-service-role"
  assume_role_policy = data.aws_iam_policy_document.codedeploy_service_assume_role.json

  tags = {
    Name = "lucent-codedeploy-service-role"
  }
}

resource "aws_iam_role_policy_attachment" "codedeploy_service_managed" {
  role       = aws_iam_role.codedeploy_service.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
}

resource "aws_codedeploy_app" "backend" {
  name             = var.codedeploy_application_name
  compute_platform = "Server"
}

resource "aws_codedeploy_deployment_group" "backend" {
  app_name               = aws_codedeploy_app.backend.name
  deployment_group_name  = var.codedeploy_deployment_group_name
  service_role_arn       = aws_iam_role.codedeploy_service.arn
  deployment_config_name = "CodeDeployDefault.OneAtATime"

  # Stage B only: adding the ASG makes CodeDeploy install the latest successful
  # revision onto replacement instances through ASG lifecycle hooks.
  autoscaling_groups = var.codedeploy_enable_asg_integration ? [aws_autoscaling_group.backend.name] : []

  dynamic "ec2_tag_filter" {
    for_each = var.codedeploy_enable_asg_integration ? [] : [1]

    content {
      key   = "Service"
      type  = "KEY_AND_VALUE"
      value = "lucent-backend"
    }
  }

  deployment_style {
    deployment_type   = "IN_PLACE"
    deployment_option = "WITH_TRAFFIC_CONTROL"
  }

  load_balancer_info {
    target_group_info {
      name = aws_lb_target_group.backend.name
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }

  outdated_instances_strategy = "UPDATE"

  depends_on = [
    aws_iam_role_policy_attachment.codedeploy_service_managed
  ]
}
