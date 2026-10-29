variable "ec2_instance_profile_name" {
  description = "Existing AWS Academy instance profile attached to private EC2 instances for management access."
  type        = string
  default     = "LabInstanceProfile"
}

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
  description = "Time allowed for a new backend instance to receive the first application deployment before ALB health failures trigger replacement."
  type        = number
  default     = 600

  validation {
    condition     = var.backend_asg_health_check_grace_seconds >= var.backend_instance_warmup_seconds
    error_message = "The Backend ASG health-check grace period must be at least the instance warmup period."
  }
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
