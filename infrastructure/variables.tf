variable "backend_ecr_repository_name" {
  description = "ECR repository name for the Lucent Backend Docker image."
  type        = string
  default     = "lucent-backend"
}

variable "backend_container_port" {
  description = "Port exposed by the Lucent Backend container on each private EC2 instance."
  type        = number
  default     = 8080
}

variable "backend_instance_type" {
  description = "Instance type used by every Lucent Backend Auto Scaling Group instance."
  type        = string
  default     = "t3.micro"
}

variable "backend_asg_min_size" {
  description = "Minimum number of healthy Lucent Backend instances maintained by the Auto Scaling Group."
  type        = number
  default     = 2

  validation {
    condition     = var.backend_asg_min_size >= 1
    error_message = "The Backend ASG minimum capacity must be at least one instance."
  }
}

variable "backend_asg_desired_capacity" {
  description = "Normal number of Lucent Backend instances started by the Auto Scaling Group."
  type        = number
  default     = 2
}

variable "backend_asg_max_size" {
  description = "Maximum number of Lucent Backend instances allowed during scale-out."
  type        = number
  default     = 4

  validation {
    condition     = var.backend_asg_max_size >= 1
    error_message = "The Backend ASG maximum capacity must be at least one instance."
  }
}

variable "backend_cpu_target_percent" {
  description = "Target average CPU utilization percentage used by the Backend target-tracking scaling policy."
  type        = number
  default     = 50

  validation {
    condition     = var.backend_cpu_target_percent > 0 && var.backend_cpu_target_percent <= 100
    error_message = "The Backend CPU target must be greater than 0 and no more than 100 percent."
  }
}

variable "backend_instance_warmup_seconds" {
  description = "Time allowed for a new Backend instance to start Docker and the application before scaling metrics use it."
  type        = number
  default     = 120

  validation {
    condition     = var.backend_instance_warmup_seconds >= 0
    error_message = "The Backend instance warmup must be zero or greater."
  }
}

variable "backend_asg_health_check_grace_seconds" {
  description = "ELB health-check grace period used only after the Backend ASG has completed CodeDeploy production promotion."
  type        = number
  default     = 600

  validation {
    condition     = var.backend_asg_health_check_grace_seconds >= var.backend_instance_warmup_seconds
    error_message = "The Backend ASG health-check grace period must be at least the instance warmup period."
  }
}

variable "backend_asg_enable_elb_health_checks" {
  description = "Persistent production health-check switch. False uses EC2 health during first CodeDeploy bootstrap; true restores ELB health checks only after CodeDeploy ASG integration and full convergence succeed."
  type        = bool
  default     = false
}

variable "alb_listener_port" {
  description = "Public HTTP listener port for the Lucent Backend Application Load Balancer."
  type        = number
  default     = 80
}

variable "frontend_nginx_port" {
  description = "Port used by Nginx on each private frontend EC2 instance."
  type        = number
  default     = 80
}

variable "codedeploy_application_name" {
  description = "CodeDeploy Server application name for immutable Lucent Backend revisions."
  type        = string
  default     = "lucent-backend"
}

variable "codedeploy_deployment_group_name" {
  description = "CodeDeploy deployment group for the Lucent Backend."
  type        = string
  default     = "lucent-backend-production"
}

variable "codedeploy_enable_asg_integration" {
  description = "Persistent Stage B switch. Pipelines derive it from the successful CodeDeploy marker and current Deployment Group association; false uses tagged current Backend instances, true attaches CodeDeploy to the Backend ASG lifecycle."
  type        = bool
  default     = false
}

# =========================
# Monitoring
# =========================

variable "monitoring_alert_email" {
  description = "Optional email address subscribed to Lucent production monitoring alerts. AWS requires recipient confirmation before notifications begin."
  type        = string
  default     = ""
}

variable "monitoring_default_enabled" {
  description = "Initial runtime value for /lucent/monitoring/enabled. Later console ON/OFF operations intentionally persist outside Terraform value reconciliation."
  type        = bool
  default     = true
}

variable "monitoring_log_retention_days" {
  description = "Retention period for centralized Lucent Backend application logs."
  type        = number
  default     = 7

  validation {
    condition     = var.monitoring_log_retention_days >= 1
    error_message = "Monitoring log retention must be at least one day."
  }
}

variable "monitoring_agent_collection_interval_seconds" {
  description = "CloudWatch Agent Memory and Disk collection interval for Backend EC2 instances."
  type        = number
  default     = 60

  validation {
    condition     = var.monitoring_agent_collection_interval_seconds >= 60
    error_message = "CloudWatch Agent collection interval must be at least 60 seconds for this t3.micro deployment."
  }
}
